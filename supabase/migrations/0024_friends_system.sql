-- 0024_friends_system.sql
--
-- The friend graph for Venttly. Mutual-opt-in: a friendship row is
-- created in 'pending' state by the requester and flips to 'accepted'
-- only when the other side accepts.
--
-- Design notes
--  - Single symmetric row per relationship (user_a < user_b lexically)
--    keeps queries simple ("WHERE auth.uid() IN (user_a, user_b)") and
--    forbids duplicate-edge bugs by construction.
--  - Status enum is small ('pending' | 'accepted'); declined or
--    rescinded requests are DELETE'd so a re-request is just a new row.
--  - Blocks live in their own table because they survive unfriending
--    and are unidirectional.
--  - All writes go through SECURITY DEFINER RPCs so we can enforce
--    "you can't accept your own request" and "no block bypass" at the
--    function body rather than relying on row policies alone.
--
-- Out of scope for this migration: DM gating on friendship (kept loose
-- for now; the existing chat_rooms request flow still applies), friend-
-- of-friend suggestions, friend activity feed ranking. Those build on
-- top of this table in follow-ups.

-- =========================================================================
-- friendships
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.friendships (
    friendship_id UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_a        UUID         NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    user_b        UUID         NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    status        TEXT         NOT NULL CHECK (status IN ('pending','accepted')),
    requested_by  UUID         NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    note          TEXT,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    accepted_at   TIMESTAMPTZ,
    UNIQUE (user_a, user_b),
    CHECK (user_a < user_b),
    CHECK (requested_by = user_a OR requested_by = user_b)
);

CREATE INDEX IF NOT EXISTS friendships_user_a_idx
    ON public.friendships (user_a, status);
CREATE INDEX IF NOT EXISTS friendships_user_b_idx
    ON public.friendships (user_b, status);

ALTER TABLE public.friendships ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "friendships participant read" ON public.friendships;
CREATE POLICY "friendships participant read"
    ON public.friendships FOR SELECT
    USING (auth.uid() IN (user_a, user_b));

GRANT SELECT ON public.friendships TO authenticated;

-- =========================================================================
-- user_blocks
-- =========================================================================
-- user_blocks already exists from migration 0002 with a block_id PK and
-- unique (blocker_id, blocked_id). We just add the optional `reason`
-- column the new RPCs surface to the UI.
CREATE TABLE IF NOT EXISTS public.user_blocks (
    block_id   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    blocker_id UUID         NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    blocked_id UUID         NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (blocker_id, blocked_id),
    CHECK (blocker_id <> blocked_id)
);
ALTER TABLE public.user_blocks ADD COLUMN IF NOT EXISTS reason TEXT;

CREATE INDEX IF NOT EXISTS user_blocks_blocked_idx
    ON public.user_blocks (blocked_id);

ALTER TABLE public.user_blocks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "blocks owner read" ON public.user_blocks;
CREATE POLICY "blocks owner read"
    ON public.user_blocks FOR SELECT
    USING (blocker_id = auth.uid());

GRANT SELECT ON public.user_blocks TO authenticated;

-- =========================================================================
-- helpers
-- =========================================================================

-- Canonical ordering so a/b are stable regardless of who initiates.
CREATE OR REPLACE FUNCTION public.friendship_pair(p_a UUID, p_b UUID)
RETURNS TABLE(user_a UUID, user_b UUID)
LANGUAGE sql IMMUTABLE AS $$
    SELECT LEAST(p_a, p_b), GREATEST(p_a, p_b);
$$;

-- Does u1 block u2 (in either direction)?
CREATE OR REPLACE FUNCTION public.has_block(p_u1 UUID, p_u2 UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.user_blocks
         WHERE (blocker_id = p_u1 AND blocked_id = p_u2)
            OR (blocker_id = p_u2 AND blocked_id = p_u1)
    );
$$;

-- =========================================================================
-- RPCs
-- =========================================================================

-- send_friend_request(target, note?)
CREATE OR REPLACE FUNCTION public.send_friend_request(
    p_target UUID,
    p_note   TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me   UUID := auth.uid();
    v_pair RECORD;
    v_id   UUID;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_target IS NULL THEN RAISE EXCEPTION 'target required'; END IF;
    IF p_target = v_me THEN RAISE EXCEPTION 'cannot friend yourself'; END IF;
    IF has_block(v_me, p_target) THEN
        RAISE EXCEPTION 'a block prevents this request';
    END IF;

    SELECT * INTO v_pair FROM friendship_pair(v_me, p_target);

    INSERT INTO friendships (user_a, user_b, status, requested_by, note)
    VALUES (v_pair.user_a, v_pair.user_b, 'pending', v_me, p_note)
    ON CONFLICT (user_a, user_b) DO NOTHING
    RETURNING friendship_id INTO v_id;

    IF v_id IS NULL THEN
        -- Existing row: surface its id so the client can update its state
        SELECT friendship_id INTO v_id
          FROM friendships
         WHERE user_a = v_pair.user_a AND user_b = v_pair.user_b;
    END IF;
    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.send_friend_request(UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_friend_request(UUID,TEXT) TO authenticated;

-- accept_friend_request(friendship_id)
CREATE OR REPLACE FUNCTION public.accept_friend_request(p_friendship UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me UUID := auth.uid();
    v_row RECORD;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    SELECT * INTO v_row FROM friendships WHERE friendship_id = p_friendship;
    IF NOT FOUND THEN RAISE EXCEPTION 'request not found'; END IF;
    IF v_me NOT IN (v_row.user_a, v_row.user_b) THEN
        RAISE EXCEPTION 'not your request';
    END IF;
    IF v_row.requested_by = v_me THEN
        RAISE EXCEPTION 'cannot accept your own request';
    END IF;
    IF v_row.status <> 'pending' THEN
        RAISE EXCEPTION 'request is not pending';
    END IF;

    UPDATE friendships
       SET status = 'accepted', accepted_at = now()
     WHERE friendship_id = p_friendship;
END $$;

REVOKE ALL ON FUNCTION public.accept_friend_request(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_friend_request(UUID) TO authenticated;

-- decline_friend_request(friendship_id) — recipient declines OR requester
-- rescinds. Both delete the row so a fresh request can be sent later.
CREATE OR REPLACE FUNCTION public.decline_friend_request(p_friendship UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me UUID := auth.uid();
    v_row RECORD;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    SELECT * INTO v_row FROM friendships WHERE friendship_id = p_friendship;
    IF NOT FOUND THEN RETURN; END IF;
    IF v_me NOT IN (v_row.user_a, v_row.user_b) THEN
        RAISE EXCEPTION 'not your request';
    END IF;
    IF v_row.status <> 'pending' THEN
        RAISE EXCEPTION 'request is not pending';
    END IF;

    DELETE FROM friendships WHERE friendship_id = p_friendship;
END $$;

REVOKE ALL ON FUNCTION public.decline_friend_request(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.decline_friend_request(UUID) TO authenticated;

-- unfriend(target) — removes an accepted friendship.
CREATE OR REPLACE FUNCTION public.unfriend(p_target UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me UUID := auth.uid();
    v_pair RECORD;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    SELECT * INTO v_pair FROM friendship_pair(v_me, p_target);
    DELETE FROM friendships
     WHERE user_a = v_pair.user_a AND user_b = v_pair.user_b
       AND status = 'accepted';
END $$;

REVOKE ALL ON FUNCTION public.unfriend(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unfriend(UUID) TO authenticated;

-- block_user(target, reason?)
CREATE OR REPLACE FUNCTION public.block_user(p_target UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me UUID := auth.uid();
    v_pair RECORD;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_target = v_me THEN RAISE EXCEPTION 'cannot block yourself'; END IF;

    INSERT INTO user_blocks (blocker_id, blocked_id, reason)
    VALUES (v_me, p_target, p_reason)
    ON CONFLICT (blocker_id, blocked_id) DO UPDATE SET reason = EXCLUDED.reason;

    -- A block tears down any existing friendship (in either status). The
    -- block itself stays — unfriending isn't enough to reverse it.
    SELECT * INTO v_pair FROM friendship_pair(v_me, p_target);
    DELETE FROM friendships
     WHERE user_a = v_pair.user_a AND user_b = v_pair.user_b;
END $$;

REVOKE ALL ON FUNCTION public.block_user(UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.block_user(UUID,TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.unblock_user(p_target UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    DELETE FROM user_blocks
     WHERE blocker_id = auth.uid() AND blocked_id = p_target;
END $$;

REVOKE ALL ON FUNCTION public.unblock_user(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unblock_user(UUID) TO authenticated;

-- =========================================================================
-- friend_status — single source of truth used everywhere on the client
-- =========================================================================
CREATE OR REPLACE FUNCTION public.friend_status(p_target UUID)
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me UUID := auth.uid();
    v_pair RECORD;
    v_row  RECORD;
BEGIN
    IF v_me IS NULL OR p_target IS NULL THEN RETURN 'none'; END IF;
    IF v_me = p_target THEN RETURN 'self'; END IF;
    IF EXISTS (
        SELECT 1 FROM user_blocks
         WHERE blocker_id = v_me AND blocked_id = p_target
    ) THEN RETURN 'blocked_by_me'; END IF;
    IF EXISTS (
        SELECT 1 FROM user_blocks
         WHERE blocker_id = p_target AND blocked_id = v_me
    ) THEN RETURN 'blocked_me'; END IF;

    SELECT * INTO v_pair FROM friendship_pair(v_me, p_target);
    SELECT * INTO v_row FROM friendships
     WHERE user_a = v_pair.user_a AND user_b = v_pair.user_b;
    IF NOT FOUND THEN RETURN 'none'; END IF;
    IF v_row.status = 'accepted' THEN RETURN 'friends'; END IF;
    IF v_row.requested_by = v_me THEN RETURN 'pending_outgoing'; END IF;
    RETURN 'pending_incoming';
END $$;

REVOKE ALL ON FUNCTION public.friend_status(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.friend_status(UUID) TO authenticated;

-- =========================================================================
-- Views — denormalised reads so the client doesn't join from Dart
-- =========================================================================

-- my_friends: accepted friendships from the caller's perspective.
-- Returns the other user's identity + when they connected. ORDER BY
-- accepted_at DESC so the list feels alive on each open.
DROP VIEW IF EXISTS public.my_friends;
CREATE VIEW public.my_friends WITH (security_invoker = true) AS
SELECT
    f.friendship_id,
    CASE WHEN f.user_a = auth.uid() THEN f.user_b ELSE f.user_a END AS friend_user_id,
    u.anonymous_pseudonym AS friend_pseudonym,
    u.avatar_seed         AS friend_avatar_seed,
    u.karma_points        AS friend_karma,
    u.is_verified         AS friend_is_verified,
    f.accepted_at,
    f.created_at
FROM public.friendships f
JOIN public.users u
  ON u.user_id = CASE WHEN f.user_a = auth.uid() THEN f.user_b ELSE f.user_a END
WHERE f.status = 'accepted' AND auth.uid() IN (f.user_a, f.user_b);

GRANT SELECT ON public.my_friends TO authenticated;

-- friend_requests_inbox: incoming pending requests addressed to the caller.
DROP VIEW IF EXISTS public.friend_requests_inbox;
CREATE VIEW public.friend_requests_inbox WITH (security_invoker = true) AS
SELECT
    f.friendship_id,
    f.requested_by   AS from_user_id,
    u.anonymous_pseudonym AS from_pseudonym,
    u.avatar_seed         AS from_avatar_seed,
    u.karma_points        AS from_karma,
    f.note,
    f.created_at
FROM public.friendships f
JOIN public.users u ON u.user_id = f.requested_by
WHERE f.status = 'pending'
  AND auth.uid() IN (f.user_a, f.user_b)
  AND f.requested_by <> auth.uid();

GRANT SELECT ON public.friend_requests_inbox TO authenticated;

-- friend_requests_outbox: outgoing pending requests the caller sent.
DROP VIEW IF EXISTS public.friend_requests_outbox;
CREATE VIEW public.friend_requests_outbox WITH (security_invoker = true) AS
SELECT
    f.friendship_id,
    CASE WHEN f.user_a = auth.uid() THEN f.user_b ELSE f.user_a END AS to_user_id,
    u.anonymous_pseudonym AS to_pseudonym,
    u.avatar_seed         AS to_avatar_seed,
    u.karma_points        AS to_karma,
    f.note,
    f.created_at
FROM public.friendships f
JOIN public.users u
  ON u.user_id = CASE WHEN f.user_a = auth.uid() THEN f.user_b ELSE f.user_a END
WHERE f.status = 'pending'
  AND auth.uid() IN (f.user_a, f.user_b)
  AND f.requested_by = auth.uid();

GRANT SELECT ON public.friend_requests_outbox TO authenticated;

-- my_blocks: users the caller has blocked.
DROP VIEW IF EXISTS public.my_blocks;
CREATE VIEW public.my_blocks WITH (security_invoker = true) AS
SELECT
    ub.blocked_id   AS user_id,
    u.anonymous_pseudonym AS pseudonym,
    u.avatar_seed         AS avatar_seed,
    ub.reason,
    ub.created_at
FROM public.user_blocks ub
JOIN public.users u ON u.user_id = ub.blocked_id
WHERE ub.blocker_id = auth.uid();

GRANT SELECT ON public.my_blocks TO authenticated;
