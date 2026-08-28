-- Preserve the hardened shadow-ban predicate from
-- 20260715231408_post_detail_visibility_reliability while exposing the two
-- new style columns. Reading users.shadow_banned directly from a
-- security-invoker view returns 42501 because mobile roles intentionally do
-- not have access to moderation-only columns.

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
  p.media_status,
  p.card_background_color,
  p.card_text_color
FROM public.posts p
LEFT JOIN public.users u ON u.user_id = p.author_id
LEFT JOIN public.personas pr
  ON pr.persona_id = p.persona_id
 AND pr.deleted_at IS NULL
LEFT JOIN public.tribes t ON t.tribe_id = p.tribe_id
WHERE (SELECT private.can_view_post_author(p.author_id));

GRANT SELECT ON public.feed_posts TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
