-- ============================================================================
-- 0071: Tribe rules + enforcement — keepers get real control.
--
--  1. Fix latent type bug: tribes.rules was JSONB (0005) but migration 0049
--     and the client treat it as TEXT → saving rules threw at runtime.
--  2. tribe_bans: removed-for-breaking-rules members cannot rejoin.
--  3. ban_tribe_member / unban_tribe_member RPCs (keeper-only) — ban also
--     kicks, and notifies the removed member with the rule they broke.
--  4. Trigger guard: banned users are blocked from re-inserting membership.
-- ============================================================================

-- 1) rules → TEXT (idempotent; preserves any JSONB string content).
--
-- The `tribe_directory` view (0064) selects t.rules, and Postgres refuses to
-- alter a column's type while a view depends on it (0A000). It's the only view
-- referencing rules, so drop it, change the type, then rebuild it (verbatim
-- 0064 definition, now with rules as TEXT). CASCADE guards against any rule/
-- view we didn't account for; nothing else depends on this view.
DROP VIEW IF EXISTS public.tribe_directory CASCADE;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'tribes'
                  AND column_name = 'rules' AND data_type = 'jsonb') THEN
        ALTER TABLE public.tribes
            ALTER COLUMN rules DROP DEFAULT,
            ALTER COLUMN rules DROP NOT NULL,
            ALTER COLUMN rules TYPE TEXT
            USING NULLIF(NULLIF(trim(both '"' from rules::text), '{}'), '');
    END IF;
END $$;

-- Rebuild tribe_directory (matches 0064; rules is now TEXT).
CREATE VIEW public.tribe_directory
WITH (security_invoker = true)
AS
SELECT
    t.tribe_id,
    t.name,
    t.slug,
    t.description,
    t.category,
    t.member_count,
    t.is_private,
    t.created_at,
    t.rules,
    t.avatar_url,
    t.banner_url,
    t.is_featured,
    t.is_suspended,
    t.keeper_id,
    u.anonymous_pseudonym AS keeper_pseudonym,
    u.avatar_seed         AS keeper_avatar_seed,
    u.is_verified         AS keeper_is_verified,
    u.karma_points        AS keeper_karma,
    t.welcome_message,
    t.theme_color,
    t.spotlight_user_id,
    sp.anonymous_pseudonym AS spotlight_pseudonym,
    sp.avatar_seed         AS spotlight_avatar_seed,
    t.spotlight_note,
    t.spotlight_set_at,
    t.chat_settings,
    t.pinned_message_id
FROM public.tribes t
LEFT JOIN public.users u  ON u.user_id  = t.keeper_id
LEFT JOIN public.users sp ON sp.user_id = t.spotlight_user_id;

GRANT SELECT ON public.tribe_directory TO authenticated, anon;

-- 2) Bans.
CREATE TABLE IF NOT EXISTS public.tribe_bans (
    tribe_id    UUID NOT NULL REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES public.users(user_id)   ON DELETE CASCADE,
    reason      TEXT,
    banned_by   UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tribe_id, user_id)
);

ALTER TABLE public.tribe_bans ENABLE ROW LEVEL SECURITY;

-- Keeper sees their tribe's ban list; a banned user can see their own ban
-- (so the app can explain why joining fails).
DROP POLICY IF EXISTS "bans keeper read" ON public.tribe_bans;
CREATE POLICY "bans keeper read" ON public.tribe_bans
    FOR SELECT USING (
        user_id = auth.uid()
        OR EXISTS (SELECT 1 FROM public.tribes t
                    WHERE t.tribe_id = tribe_bans.tribe_id
                      AND t.keeper_id = auth.uid())
    );
-- All writes go through the SECURITY DEFINER RPCs below.

-- 3) Ban / unban RPCs.
CREATE OR REPLACE FUNCTION public.ban_tribe_member(
    p_tribe_id UUID,
    p_user_id  UUID,
    p_reason   TEXT DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_keeper UUID;
    v_tribe_name TEXT;
BEGIN
    SELECT keeper_id, name INTO v_keeper, v_tribe_name
      FROM tribes WHERE tribe_id = p_tribe_id;
    IF v_keeper IS NULL OR v_keeper <> auth.uid() THEN
        RAISE EXCEPTION 'Only the keeper can remove members';
    END IF;
    IF p_user_id = auth.uid() THEN
        RAISE EXCEPTION 'Keepers cannot ban themselves';
    END IF;

    INSERT INTO tribe_bans (tribe_id, user_id, reason, banned_by)
    VALUES (p_tribe_id, p_user_id, p_reason, auth.uid())
    ON CONFLICT (tribe_id, user_id)
    DO UPDATE SET reason = EXCLUDED.reason, banned_by = EXCLUDED.banned_by;

    DELETE FROM tribe_members
     WHERE tribe_id = p_tribe_id AND user_id = p_user_id;

    INSERT INTO notifications (user_id, kind, payload)
    VALUES (p_user_id, 'moderation_action', jsonb_build_object(
        'message', 'You were removed from ' || COALESCE(v_tribe_name, 'a tribe')
                   || CASE WHEN p_reason IS NULL OR p_reason = ''
                           THEN ' for breaking the tribe rules.'
                           ELSE ': ' || p_reason END,
        'tribe_id', p_tribe_id
    ));
END $$;

CREATE OR REPLACE FUNCTION public.unban_tribe_member(
    p_tribe_id UUID,
    p_user_id  UUID
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM tribes
                    WHERE tribe_id = p_tribe_id AND keeper_id = auth.uid()) THEN
        RAISE EXCEPTION 'Only the keeper can lift bans';
    END IF;
    DELETE FROM tribe_bans
     WHERE tribe_id = p_tribe_id AND user_id = p_user_id;
END $$;

REVOKE ALL ON FUNCTION public.ban_tribe_member(UUID, UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.unban_tribe_member(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ban_tribe_member(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unban_tribe_member(UUID, UUID) TO authenticated;

-- 4) Banned users cannot rejoin — enforced at the table, not the client.
CREATE OR REPLACE FUNCTION public.tribe_members_ban_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM tribe_bans
                WHERE tribe_id = NEW.tribe_id AND user_id = NEW.user_id) THEN
        RAISE EXCEPTION 'You were removed from this tribe and cannot rejoin.'
              USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_tribe_members_ban_guard ON public.tribe_members;
CREATE TRIGGER trg_tribe_members_ban_guard
    BEFORE INSERT ON public.tribe_members
    FOR EACH ROW EXECUTE FUNCTION public.tribe_members_ban_guard();

NOTIFY pgrst, 'reload schema';
