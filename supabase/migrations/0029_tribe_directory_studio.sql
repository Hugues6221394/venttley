-- 0029_tribe_directory_studio.sql
--
-- Extend tribe_directory with the studio columns added in 0028 so
-- tribeBySlug returns welcome_message + theme_color + spotlight info
-- in a single query. Backward compat: every existing column is still
-- present in the same order.
--
-- Spotlight user is LEFT JOINed so the view also surfaces the
-- spotlighted member's pseudonym + avatar in one round-trip.

CREATE OR REPLACE VIEW public.tribe_directory
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
    -- Studio fields (migration 0028)
    t.welcome_message,
    t.theme_color,
    t.spotlight_user_id,
    sp.anonymous_pseudonym AS spotlight_pseudonym,
    sp.avatar_seed         AS spotlight_avatar_seed,
    t.spotlight_note,
    t.spotlight_set_at
FROM public.tribes t
LEFT JOIN public.users u  ON u.user_id  = t.keeper_id
LEFT JOIN public.users sp ON sp.user_id = t.spotlight_user_id;

GRANT SELECT ON public.tribe_directory TO authenticated, anon;
