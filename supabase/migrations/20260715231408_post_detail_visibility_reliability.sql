-- Keep post visibility consistent across personal_feed, feed_posts, and
-- direct post-detail reads without exposing users.shadow_banned to clients.
--
-- Migration 0117 referenced shadow_banned directly from a security-invoker
-- view. Mobile roles intentionally have column-level access to public profile
-- fields only, so PostgREST could return 42501 for feed_posts while the
-- SECURITY DEFINER personal_feed RPC still worked. The UI then opened an empty
-- thread for a post it had just rendered.

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO anon, authenticated;

CREATE OR REPLACE FUNCTION private.can_view_post_author(p_author_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    p_author_id IS NULL
    OR p_author_id = (SELECT auth.uid())
    OR COALESCE(
      (
        SELECT u.shadow_banned IS NOT TRUE
          FROM public.users u
         WHERE u.user_id = p_author_id
      ),
      TRUE
    );
$$;

REVOKE ALL ON FUNCTION private.can_view_post_author(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.can_view_post_author(UUID)
  TO anon, authenticated;

-- The base-table policy remains the source of truth for deleted and private
-- Tribe posts, with shadow-ban visibility added to the same decision.
DROP POLICY IF EXISTS "posts readable" ON public.posts;
CREATE POLICY "posts readable"
  ON public.posts FOR SELECT
  TO anon, authenticated
  USING (
    deleted_at IS NULL
    AND (SELECT private.can_view_post_author(author_id))
    AND (
      tribe_id IS NULL
      OR NOT EXISTS (
        SELECT 1
          FROM public.tribes t
         WHERE t.tribe_id = posts.tribe_id
           AND t.is_private
      )
      OR EXISTS (
        SELECT 1
          FROM public.tribe_members tm
         WHERE tm.tribe_id = posts.tribe_id
           AND tm.user_id = (SELECT auth.uid())
      )
    )
  );

-- Rebuild the API view without reading the restricted moderation column as
-- the caller. security_invoker remains enabled so post/private-Tribe RLS is
-- still enforced by the underlying tables.
CREATE OR REPLACE VIEW public.feed_posts WITH (security_invoker = true) AS
SELECT
  p.post_id,
  p.author_id,
  COALESCE('@' || pr.pseudonym, '@' || u.anonymous_pseudonym, '@anonymous')
    AS author_pseudonym,
  COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb')
    AS author_avatar_seed,
  CASE WHEN p.persona_id IS NULL THEN u.profile_photo_url ELSE NULL::TEXT END
    AS author_profile_photo_url,
  COALESCE(u.is_verified, FALSE) AS author_is_verified,
  COALESCE(u.karma_points, 0) AS author_karma,
  p.persona_id,
  t.name AS tribe_name,
  t.slug AS tribe_slug,
  p.tribe_id,
  p.space_id,
  p.category_name,
  p.post_type,
  p.content,
  p.post_mood,
  p.is_whisper,
  p.location_bucket,
  p.likes_count,
  p.comments_count,
  p.view_count,
  p.image_url,
  p.audio_url,
  p.audio_duration_seconds,
  p.crisis_level,
  p.created_at,
  p.edited_at,
  p.deleted_at,
  p.locked_at,
  p.is_keeper_pick,
  p.keeper_pick_at,
  p.media_status
FROM public.posts p
LEFT JOIN public.users u ON u.user_id = p.author_id
LEFT JOIN public.personas pr
  ON pr.persona_id = p.persona_id
 AND pr.deleted_at IS NULL
LEFT JOIN public.tribes t ON t.tribe_id = p.tribe_id
WHERE (SELECT private.can_view_post_author(p.author_id));

GRANT SELECT ON public.feed_posts TO anon, authenticated;

COMMENT ON FUNCTION private.can_view_post_author(UUID) IS
  'Internal visibility predicate for shadow-banned post authors.';

NOTIFY pgrst, 'reload schema';
