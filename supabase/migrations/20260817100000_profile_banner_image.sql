-- A background image on the public profile.
--
-- Today `_HeroBanner` blurs the profile *photo* to fill the strip behind the
-- avatar, which means the banner is never a choice — it is the same picture
-- twice, once sharp and once out of focus. This gives people a second image
-- they actually pick.
--
-- Mirrors set_user_profile_photo exactly, including returning the previous
-- storage path so the caller can delete the file it replaced. Without that a
-- user who changes their banner five times leaves five orphaned objects in the
-- bucket paid for by the project.
--
-- Storage reuses the existing `profile-photos` bucket under a `banner-` name
-- prefix rather than adding a sixth bucket: same RLS, same size limits, same
-- mime allow-list, and — importantly — already covered by the EXIF scrubber at
-- the upload boundary, so a banner cannot leak GPS either.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS profile_banner_path TEXT,
  ADD COLUMN IF NOT EXISTS profile_banner_url TEXT;

-- The public profile RPC returns this to every viewer, friend or not, for the
-- same reason the bio does: it is something the person chose to publish.
GRANT SELECT (profile_banner_url) ON public.users TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.set_user_profile_banner(
  p_path TEXT,
  p_url TEXT
) RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_old TEXT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  -- Only ever your own row: the id comes from the session, never the client.
  SELECT u.profile_banner_path INTO v_old
    FROM public.users AS u
   WHERE u.user_id = v_me
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'profile not found'; END IF;

  UPDATE public.users
     SET profile_banner_path = p_path,
         profile_banner_url = p_url
   WHERE user_id = v_me;

  RETURN v_old;
END;
$$;

REVOKE ALL ON FUNCTION public.set_user_profile_banner(TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_user_profile_banner(TEXT, TEXT)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.clear_user_profile_banner()
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_old TEXT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT u.profile_banner_path INTO v_old
    FROM public.users AS u
   WHERE u.user_id = v_me
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'profile not found'; END IF;

  UPDATE public.users
     SET profile_banner_path = NULL,
         profile_banner_url = NULL
   WHERE user_id = v_me;

  RETURN v_old;
END;
$$;

REVOKE ALL ON FUNCTION public.clear_user_profile_banner() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clear_user_profile_banner() TO authenticated;

-- Add the banner to the public profile payload. Everything else about this
-- function is unchanged from 20260816090000; only the v_user block gains a
-- field, so the diff against that migration is one line.
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
        'user_id',            u.user_id,
        'pseudonym',          u.anonymous_pseudonym,
        'avatar_seed',        u.avatar_seed,
        'profile_photo_url',  u.profile_photo_url,
        'profile_banner_url', u.profile_banner_url,
        'bio',                u.bio,
        'pronouns',           u.pronouns,
        'karma',              u.karma_points,
        'is_verified',        u.is_verified,
        'joined_at',          u.created_at,
        'current_mood',       u.current_mood,
        'account_status',     u.account_status,
        'safety_tier',        u.safety_tier
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

REVOKE ALL ON FUNCTION public.user_profile_summary(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.user_profile_summary(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.user_profile_summary(UUID) TO authenticated;
