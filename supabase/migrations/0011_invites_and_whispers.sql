-- ============================================================================
-- Venttly | Migration 0011 — Tribe invitations + Whispers (24h ephemeral)
--
-- (a) Active recruitment: Keepers can invite specific members to their tribe.
--     The invited user sees an invitation card in their notifications and can
--     accept (joining the tribe) or decline.
--
-- (b) Whispers: a 24h ephemeral post toggle. Posts flagged `is_whisper = true`
--     vanish from the feed when they age past 24 hours. We don't hard-delete
--     them — older clients still need the underlying row for comment
--     threads, and a scheduled job can purge them later.
-- ============================================================================

-- 1) Tribe invitations ----------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tribe_invites (
    invite_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tribe_id         UUID NOT NULL
        REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
    invited_user_id  UUID NOT NULL
        REFERENCES public.users(user_id) ON DELETE CASCADE,
    invited_by       UUID
        REFERENCES public.users(user_id) ON DELETE SET NULL,
    message          TEXT,
    status           TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'accepted', 'declined')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_at       TIMESTAMPTZ,
    UNIQUE (tribe_id, invited_user_id)
);

CREATE INDEX IF NOT EXISTS idx_tribe_invites_invitee
    ON public.tribe_invites(invited_user_id, created_at DESC)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_tribe_invites_tribe
    ON public.tribe_invites(tribe_id, created_at DESC);

ALTER TABLE public.tribe_invites ENABLE ROW LEVEL SECURITY;

-- The keeper of the tribe can SELECT all invites against their tribe.
-- The invited user can SELECT their own invites.
DROP POLICY IF EXISTS "invites read" ON public.tribe_invites;
CREATE POLICY "invites read"
    ON public.tribe_invites FOR SELECT
    USING (
        invited_user_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.tribes t
             WHERE t.tribe_id = tribe_invites.tribe_id
               AND t.keeper_id = auth.uid()
        )
    );

-- Only the keeper can insert (invited_by must match auth.uid()).
DROP POLICY IF EXISTS "invites keeper insert" ON public.tribe_invites;
CREATE POLICY "invites keeper insert"
    ON public.tribe_invites FOR INSERT
    WITH CHECK (
        invited_by = auth.uid()
        AND EXISTS (
            SELECT 1 FROM public.tribes t
             WHERE t.tribe_id = tribe_invites.tribe_id
               AND t.keeper_id = auth.uid()
        )
    );

-- Only the invited user can flip status (accept/decline).
DROP POLICY IF EXISTS "invites invitee update" ON public.tribe_invites;
CREATE POLICY "invites invitee update"
    ON public.tribe_invites FOR UPDATE
    USING (invited_user_id = auth.uid())
    WITH CHECK (invited_user_id = auth.uid());

-- Notification trigger: when an invite is created, drop a row in
-- notifications so the bell badge picks it up.
CREATE OR REPLACE FUNCTION public.trg_notify_tribe_invite()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    tribe_name TEXT;
BEGIN
    SELECT name INTO tribe_name FROM public.tribes WHERE tribe_id = NEW.tribe_id;
    INSERT INTO public.notifications(user_id, kind, payload, is_read)
    VALUES (
        NEW.invited_user_id,
        'tribe_invite',
        jsonb_build_object(
            'title', 'Tribe invitation',
            'body',  'You were invited to join ' || COALESCE(tribe_name, 'a Tribe'),
            'tribe_id', NEW.tribe_id,
            'invite_id', NEW.invite_id
        ),
        false
    );
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tribe_invites_notify ON public.tribe_invites;
CREATE TRIGGER tribe_invites_notify
    AFTER INSERT ON public.tribe_invites
    FOR EACH ROW EXECUTE FUNCTION public.trg_notify_tribe_invite();

-- 2) Whispers --------------------------------------------------------------
ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS is_whisper BOOLEAN NOT NULL DEFAULT FALSE;

-- Partial index so the "live whispers" filter is cheap.
CREATE INDEX IF NOT EXISTS idx_posts_whispers
    ON public.posts(created_at DESC)
    WHERE is_whisper = true AND deleted_at IS NULL;

-- Refresh feed_posts so the client can see the flag in one fetch.
DROP VIEW IF EXISTS public.feed_posts;
CREATE VIEW public.feed_posts WITH (security_invoker = true) AS
SELECT
    p.post_id,
    p.author_id,
    COALESCE('@' || u.anonymous_pseudonym, '@anonymous') AS author_pseudonym,
    COALESCE(u.avatar_seed, 'default-orb')               AS author_avatar_seed,
    COALESCE(u.is_verified, false)                       AS author_is_verified,
    COALESCE(u.karma_points, 0)                          AS author_karma,
    t.name AS tribe_name,
    t.slug AS tribe_slug,
    p.tribe_id,
    p.category_name,
    p.post_type,
    p.content,
    p.post_mood,
    p.is_whisper,
    p.likes_count,
    p.comments_count,
    p.created_at,
    p.deleted_at
FROM public.posts p
LEFT JOIN public.users  u ON u.user_id  = p.author_id
LEFT JOIN public.tribes t ON t.tribe_id = p.tribe_id;
GRANT SELECT ON public.feed_posts TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
