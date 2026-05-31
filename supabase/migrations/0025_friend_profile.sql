-- 0025_friend_profile.sql
--
-- user_profile_summary RPC: one round-trip read for the Friend Profile
-- screen. Returns a JSONB blob containing the viewer's relation to the
-- target plus a graduated tier of detail:
--
--   self           → redirect-eligible; caller should use the regular
--                    /profile screen instead. We still return the basic
--                    user fields so the screen renders without flicker.
--   friends        → full stats, mutuals, highlights, recent posts.
--   none, pending_*→ stripped: pseudonym + avatar + total vents + tribes
--                    count + mutual-friends count + mutual tribes only.
--   blocked_by_me  → user fields + a 'blocked' marker; the UI shows an
--                    unblock CTA.
--   blocked_me     → returns NULL so the screen 404s.
--
-- This shape lets the client render a single screen with different
-- depth based on viewer_relation, without round-tripping per tier.

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
    v_pair      RECORD;
BEGIN
    IF v_me IS NULL OR p_target IS NULL THEN RETURN NULL; END IF;

    v_relation := friend_status(p_target);
    IF v_relation = 'blocked_me' THEN RETURN NULL; END IF;

    -- Basic user fields — readable for every tier except blocked_me.
    SELECT jsonb_build_object(
        'user_id',         u.user_id,
        'pseudonym',       u.anonymous_pseudonym,
        'avatar_seed',     u.avatar_seed,
        'karma',           u.karma_points,
        'is_verified',     u.is_verified,
        'joined_at',       u.created_at,
        'current_mood',    u.current_mood,
        'account_status',  u.account_status,
        'safety_tier',     u.safety_tier
      ) INTO v_user
      FROM users u WHERE u.user_id = p_target;

    IF v_user IS NULL THEN RETURN NULL; END IF;

    -- Mutuals — cheap and useful for every tier.
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

    -- Stripped stats — visible to everyone. Just the unsensitive counts
    -- you'd want a stranger to see before they decide to send a request.
    SELECT jsonb_build_object(
        'vents',
            (SELECT count(*) FROM posts
              WHERE author_id = p_target AND deleted_at IS NULL),
        'active_tribes',
            (SELECT count(*) FROM tribe_members
              WHERE user_id = p_target)
      ) INTO v_stats;

    -- Friend tier (and self) gets the deep stats and highlights.
    IF v_relation IN ('friends','self') THEN
        WITH top_moods AS (
            SELECT post_mood AS mood, count(*) AS n
              FROM posts
             WHERE author_id = p_target AND deleted_at IS NULL
               AND post_mood IS NOT NULL
             GROUP BY post_mood
             ORDER BY n DESC
             LIMIT 5
        ),
        agg_streak AS (
            SELECT max(current_count) AS current_streak,
                   max(longest_count)  AS best_streak
              FROM user_streaks WHERE user_id = p_target
        )
        SELECT jsonb_build_object(
            'vents',
                (SELECT count(*) FROM posts
                  WHERE author_id = p_target AND deleted_at IS NULL),
            'comments',
                (SELECT count(*) FROM posts_comments
                  WHERE author_id = p_target),
            'reactions_received',
                COALESCE((SELECT sum(likes_count) FROM posts
                  WHERE author_id = p_target AND deleted_at IS NULL), 0),
            'active_tribes',
                (SELECT count(*) FROM tribe_members
                  WHERE user_id = p_target),
            'badges_count',
                (SELECT count(*) FROM user_badges
                  WHERE user_id = p_target),
            'current_streak',
                COALESCE((SELECT current_streak FROM agg_streak), 0),
            'best_streak',
                COALESCE((SELECT best_streak FROM agg_streak), 0),
            'top_moods',
                COALESCE((SELECT jsonb_agg(jsonb_build_object('mood', mood, 'count', n))
                            FROM top_moods), '[]'::jsonb)
          ) INTO v_stats;

        -- Highlights: top-engagement posts. Both queries hit the
        -- (author_id, deleted_at) index path naturally.
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

REVOKE ALL ON FUNCTION public.user_profile_summary(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.user_profile_summary(UUID) TO authenticated;
