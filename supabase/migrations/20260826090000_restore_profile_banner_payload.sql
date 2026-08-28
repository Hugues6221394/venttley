-- Restore the profile banner on other people's profiles, and stop it being
-- lost again.
--
-- Seven migrations define public.user_profile_summary and only the newest two
-- return profile_banner_url / profile_banner_offset. CREATE OR REPLACE FUNCTION
-- means the last one *run* wins, not the last one written — so applying any
-- older file by hand silently reverts the banner for every viewer while the
-- owner's own profile, which reads public.users directly, keeps showing it.
-- That is exactly what happened: the columns were present on the row and absent
-- from the payload, and nothing said so.
--
-- Two parts. First, put the authoritative body back.

CREATE OR REPLACE FUNCTION public.user_profile_summary(p_target UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
    v_me        UUID := auth.uid();
    v_relation  TEXT;
    v_user      JSONB;
    v_stats     JSONB;
    v_mutuals   JSONB;
    v_highlights JSONB;
BEGIN
    IF v_me IS NULL OR p_target IS NULL THEN RETURN NULL; END IF;

    v_relation := friend_status(p_target);
    IF v_relation = 'blocked_me' THEN RETURN NULL; END IF;

    SELECT jsonb_build_object(
        'user_id',               u.user_id,
        'pseudonym',             u.anonymous_pseudonym,
        'avatar_seed',           u.avatar_seed,
        'profile_photo_url',     u.profile_photo_url,
        'profile_banner_url',    u.profile_banner_url,
        'profile_banner_offset', u.profile_banner_offset,
        'bio',                   u.bio,
        'pronouns',              u.pronouns,
        'karma',                 u.karma_points,
        'is_verified',           u.is_verified,
        'joined_at',             u.created_at,
        'current_mood',          u.current_mood,
        'account_status',        u.account_status,
        'safety_tier',           u.safety_tier
      ) INTO v_user
      FROM users u WHERE u.user_id = p_target;

    IF v_user IS NULL THEN RETURN NULL; END IF;

    WITH my_friends AS (
        SELECT CASE WHEN user_a = v_me THEN user_b ELSE user_a END AS fid
          FROM friendships
         WHERE status = 'accepted' AND v_me IN (user_a, user_b)
    ),
    their_friends AS (
        SELECT CASE WHEN user_a = p_target THEN user_b ELSE user_a END AS fid
          FROM friendships
         WHERE status = 'accepted' AND p_target IN (user_a, user_b)
    ),
    intersect_friends AS (
        SELECT m.fid FROM my_friends m INNER JOIN their_friends t USING (fid)
    ),
    intersect_tribes AS (
        SELECT t1.tribe_id, t.name, t.slug
          FROM tribe_members t1
          JOIN tribe_members t2
            ON t1.tribe_id = t2.tribe_id AND t2.user_id = p_target
          JOIN tribes t ON t.tribe_id = t1.tribe_id
         WHERE t1.user_id = v_me
    )
    SELECT jsonb_build_object(
        'mutual_friends_count', (SELECT count(*) FROM intersect_friends),
        'mutual_friend_sample',
            (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'user_id', u.user_id,
                  'pseudonym', u.anonymous_pseudonym,
                  'avatar_seed', u.avatar_seed
              )), '[]'::jsonb)
               FROM (
                   SELECT fid FROM intersect_friends LIMIT 6
               ) f JOIN users u ON u.user_id = f.fid),
        'mutual_tribes',
            (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'tribe_id', tribe_id, 'name', name, 'slug', slug
              )), '[]'::jsonb) FROM intersect_tribes)
      ) INTO v_mutuals;

    WITH agg_streak AS (
        SELECT max(current_count) AS current_streak,
               max(longest_count)  AS best_streak
          FROM user_streaks WHERE user_id = p_target
    )
    SELECT jsonb_build_object(
        'vents',
            (SELECT count(*) FROM posts
              WHERE author_id = p_target AND deleted_at IS NULL),
        'active_tribes',
            (SELECT count(*) FROM tribe_members
              WHERE user_id = p_target),
        'comments',
            (SELECT count(*) FROM posts_comments
              WHERE author_id = p_target AND deleted_at IS NULL)
          + (SELECT count(*) FROM whisper_comments
              WHERE author_id = p_target AND deleted_at IS NULL),
        'reactions_received',
            COALESCE((SELECT sum(likes_count) FROM posts
              WHERE author_id = p_target AND deleted_at IS NULL), 0)
          + COALESCE((SELECT sum(likes_count) FROM posts_comments
              WHERE author_id = p_target AND deleted_at IS NULL), 0),
        'badges_count',
            (SELECT count(*) FROM user_badges
              WHERE user_id = p_target),
        'current_streak',
            COALESCE((SELECT current_streak FROM agg_streak), 0),
        'best_streak',
            COALESCE((SELECT best_streak FROM agg_streak), 0)
      ) INTO v_stats;

    IF v_relation IN ('friends','self') THEN
        WITH top_moods AS (
            SELECT post_mood AS mood, count(*) AS n
              FROM posts
             WHERE author_id = p_target AND deleted_at IS NULL
               AND post_mood IS NOT NULL
             GROUP BY post_mood
             ORDER BY n DESC
             LIMIT 5
        )
        SELECT v_stats || jsonb_build_object(
            'top_moods',
                COALESCE((SELECT jsonb_agg(jsonb_build_object(
                    'mood', mood, 'count', n
                )) FROM top_moods), '[]'::jsonb)
          ) INTO v_stats;

        WITH dates AS (
            SELECT (current_date - g)::date AS day
              FROM generate_series(0, 89) g
        ),
        post_counts AS (
            SELECT (created_at AT TIME ZONE 'UTC')::date AS day, count(*) AS n
              FROM posts
             WHERE author_id = p_target
               AND deleted_at IS NULL
               AND created_at > now() - interval '91 days'
             GROUP BY 1
        ),
        comment_counts AS (
            SELECT (created_at AT TIME ZONE 'UTC')::date AS day, count(*) AS n
              FROM posts_comments
             WHERE author_id = p_target
               AND deleted_at IS NULL
               AND created_at > now() - interval '91 days'
             GROUP BY 1
        ),
        merged AS (
            SELECT d.day,
                   COALESCE(pc.n, 0) + COALESCE(cc.n, 0) AS count
              FROM dates d
              LEFT JOIN post_counts pc ON pc.day = d.day
              LEFT JOIN comment_counts cc ON cc.day = d.day
        )
        SELECT jsonb_build_object(
            'most_liked',
                (SELECT jsonb_build_object(
                    'post_id', p.post_id,
                    'content', left(p.content, 240),
                    'likes', p.likes_count,
                    'comments', p.comments_count,
                    'created_at', p.created_at,
                    'category', p.category_name
                 )
                 FROM posts p
                 WHERE p.author_id = p_target AND p.deleted_at IS NULL
                 ORDER BY p.likes_count DESC, p.created_at DESC
                 LIMIT 1),
            'most_commented',
                (SELECT jsonb_build_object(
                    'post_id', p.post_id,
                    'content', left(p.content, 240),
                    'likes', p.likes_count,
                    'comments', p.comments_count,
                    'created_at', p.created_at,
                    'category', p.category_name
                 )
                 FROM posts p
                 WHERE p.author_id = p_target AND p.deleted_at IS NULL
                 ORDER BY p.comments_count DESC, p.created_at DESC
                 LIMIT 1),
            'recent_posts',
                COALESCE((
                  SELECT jsonb_agg(jsonb_build_object(
                      'post_id', p.post_id,
                      'content', left(p.content, 240),
                      'likes', p.likes_count,
                      'comments', p.comments_count,
                      'created_at', p.created_at,
                      'category', p.category_name,
                      'mood', p.post_mood,
                      'crisis_level', p.crisis_level
                  ) ORDER BY p.created_at DESC)
                  FROM (
                    SELECT * FROM posts
                     WHERE author_id = p_target AND deleted_at IS NULL
                     ORDER BY created_at DESC LIMIT 6
                  ) p
                ), '[]'::jsonb),
            'badges',
                COALESCE((
                  SELECT jsonb_agg(jsonb_build_object(
                      'badge_key', b.badge_key,
                      'label', d.label,
                      'icon', d.icon,
                      'tier', d.tier,
                      'awarded_at', b.awarded_at
                  ) ORDER BY b.awarded_at DESC)
                  FROM user_badges b
                  LEFT JOIN badge_definitions d ON d.badge_key = b.badge_key
                  WHERE b.user_id = p_target
                ), '[]'::jsonb),
            'heatmap',
                COALESCE((
                  SELECT jsonb_agg(jsonb_build_object(
                      'day',   to_char(day, 'YYYY-MM-DD'),
                      'count', count
                  ) ORDER BY day)
                  FROM merged
                ), '[]'::jsonb)
          ) INTO v_highlights;
    ELSE
        v_highlights := jsonb_build_object();
    END IF;

    RETURN jsonb_build_object(
        'viewer_relation', v_relation,
        'user',            v_user,
        'stats',           v_stats,
        'mutuals',         v_mutuals,
        'highlights',      v_highlights
    );
END $$;

REVOKE ALL ON FUNCTION public.user_profile_summary(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.user_profile_summary(UUID) TO authenticated;

-- Second, stop this recurring.
--
-- The banner now also has a home that nothing else owns. user_profile_summary
-- is a large payload that seven migrations have each had a reason to touch;
-- this returns two columns and has exactly one reason to change, so no future
-- migration will quietly drop it on its way to editing something else. The
-- client falls back to it when the summary comes back without the keys, which
-- means a mis-ordered migration costs you the crop anchor for one release
-- instead of every banner in the app.
--
-- Same visibility rule as the summary: signed in, and not blocked by the
-- target. Nothing here is private — a banner is shown to everyone who can open
-- the profile — but it should not be readable by someone they have blocked.
CREATE OR REPLACE FUNCTION public.user_profile_banner(p_target UUID)
RETURNS TABLE (profile_banner_url TEXT, profile_banner_offset REAL)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
BEGIN
  IF v_me IS NULL OR p_target IS NULL THEN RETURN; END IF;
  IF friend_status(p_target) = 'blocked_me' THEN RETURN; END IF;

  RETURN QUERY
  SELECT u.profile_banner_url::TEXT,
         u.profile_banner_offset::REAL
    FROM public.users AS u
   WHERE u.user_id = p_target;
END $$;

REVOKE ALL ON FUNCTION public.user_profile_banner(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.user_profile_banner(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
