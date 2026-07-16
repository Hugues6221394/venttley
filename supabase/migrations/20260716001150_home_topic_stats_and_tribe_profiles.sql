-- Authoritative Home topic totals and complete Tribe identity media.
--
-- Counts are calculated from feed_posts so the caller's post/private-Tribe
-- RLS, deletion rules, and shadow-ban visibility remain the source of truth.

CREATE OR REPLACE FUNCTION public.trending_topic_stats(p_limit INT DEFAULT 8)
RETURNS TABLE (
  category_name TEXT,
  post_count INT,
  comment_count INT,
  reaction_count INT,
  trend_score DOUBLE PRECISION
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  WITH category_stats AS (
    SELECT
      f.category_name::TEXT AS category_name,
      COUNT(*)::INT AS post_count,
      COALESCE(SUM(f.comments_count), 0)::INT AS comment_count,
      COALESCE(SUM(f.likes_count), 0)::INT AS reaction_count,
      COALESCE(
        SUM(
          CASE
            WHEN f.created_at >= NOW() - INTERVAL '30 days' THEN
              (1 + f.likes_count + (f.comments_count * 1.6)) /
              POWER(
                GREATEST(
                  EXTRACT(EPOCH FROM (NOW() - f.created_at)) / 3600 + 2,
                  2
                ),
                0.55
              )
            ELSE 0
          END
        ),
        0
      )::DOUBLE PRECISION AS trend_score
    FROM public.feed_posts f
    WHERE NOT f.is_whisper
      AND f.category_name IS NOT NULL
      AND BTRIM(f.category_name) <> ''
    GROUP BY f.category_name
    HAVING COUNT(*) FILTER (
      WHERE f.created_at >= NOW() - INTERVAL '30 days'
    ) > 0
  )
  SELECT
    s.category_name,
    s.post_count,
    s.comment_count,
    s.reaction_count,
    s.trend_score
  FROM category_stats s
  ORDER BY
    s.trend_score DESC,
    s.comment_count DESC,
    s.post_count DESC,
    s.category_name ASC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 8), 20));
$$;

REVOKE ALL ON FUNCTION public.trending_topic_stats(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trending_topic_stats(INT)
  TO anon, authenticated;

-- Append keeper/spotlight profile photos without disturbing the established
-- tribe_directory column order used by SETOF callers.
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
  u.avatar_seed AS keeper_avatar_seed,
  u.is_verified AS keeper_is_verified,
  u.karma_points AS keeper_karma,
  t.welcome_message,
  t.theme_color,
  t.spotlight_user_id,
  sp.anonymous_pseudonym AS spotlight_pseudonym,
  sp.avatar_seed AS spotlight_avatar_seed,
  t.spotlight_note,
  t.spotlight_set_at,
  t.chat_settings,
  t.pinned_message_id,
  u.profile_photo_url AS keeper_profile_photo_url,
  sp.profile_photo_url AS spotlight_profile_photo_url
FROM public.tribes t
LEFT JOIN public.users u ON u.user_id = t.keeper_id
LEFT JOIN public.users sp ON sp.user_id = t.spotlight_user_id;

GRANT SELECT ON public.tribe_directory TO anon, authenticated;

COMMENT ON FUNCTION public.trending_topic_stats(INT) IS
  'RLS-aware, authoritative post/reply totals for active feed categories.';

NOTIFY pgrst, 'reload schema';
