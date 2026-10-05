-- The ranker learns what the readers already learned: author means voice.
--
-- 20261077090000 revoked posts.author_id so a persona post could not be joined
-- to the account behind it. personal_feed reads that column twelve times, and
-- it is SECURITY INVOKER — which is deliberate, it is what keeps row level
-- security on — so the revoke took the feed down with it. Caught against
-- production: "permission denied for table posts" from inside the home screen.
--
-- Fixed forward rather than by restoring the grant. The grant is the leak, and
-- the twelve references wanted the voice anyway:
--
--   the arms            carry feed_author_key as author_id, so diversity,
--                       affinity and muting all key on the persona
--   "people you like"   accumulates on the persona, not the human behind it
--   the friends arm     joins display_author_id — you are friends with an
--                       account, never with a persona, so a persona post stops
--                       inheriting the friend bonus that would have marked it
--   the new-account gate asks about the account behind the persona through a
--                       definer helper, because the caller may not see it
--
-- Everything downstream of the arms is untouched: the alias is still
-- `author_id`, so scoring, the diversity window and the slot interleave read
-- exactly as before — they just read a different identity.

CREATE OR REPLACE FUNCTION public.personal_feed(p_limit integer DEFAULT 20, p_mode text DEFAULT 'foryou'::text, p_anchor timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_position integer DEFAULT NULL::integer, p_category text DEFAULT NULL::text, p_mood text DEFAULT NULL::text, p_tribe_slug text DEFAULT NULL::text, p_location text DEFAULT NULL::text)
 RETURNS TABLE(post_id uuid, author_id uuid, author_pseudonym text, author_avatar_seed character varying, author_profile_photo_url text, author_is_verified boolean, author_karma integer, tribe_name character varying, tribe_slug text, tribe_id uuid, category_name character varying, post_type character varying, content text, post_mood mood_badge_type, is_whisper boolean, location_bucket text, likes_count integer, comments_count integer, view_count integer, image_url text, audio_url text, audio_duration_seconds integer, crisis_level text, created_at timestamp with time zone, deleted_at timestamp with time zone, personal_score double precision, music_track_id uuid, music_start_ms integer, music_duration_ms integer, music_volume real, goal_reached_at timestamp with time zone, media_status text, card_background_color text, card_text_color text, is_story boolean, story_audience text, feed_position integer, feed_anchor timestamp with time zone)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_uid    UUID := (SELECT auth.uid());
  v_bucket TEXT;
  v_tribe  UUID;
  v_anchor TIMESTAMPTZ := COALESCE(p_anchor, clock_timestamp());
  v_limit  INT := GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
  v_after  INT := GREATEST(0, COALESCE(p_after_position, 0));
  v_pool   INT;
  v_mode   TEXT := COALESCE(p_mode, 'foryou');
  v_key    TEXT;
  v_stamp  TEXT;
  v_ids    UUID[];
  v_scores DOUBLE PRECISION[];
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF v_mode NOT IN ('foryou', 'hot', 'fresh') THEN
    RAISE EXCEPTION 'invalid_mode';
  END IF;

  v_pool := LEAST(1200, GREATEST(400, (v_after + v_limit) * 4));
  v_stamp := to_char(v_anchor AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US');
  v_key := md5(
    v_mode || '|' || COALESCE(p_category, '') || '|' || COALESCE(p_mood, '')
    || '|' || COALESCE(p_tribe_slug, '') || '|' || COALESCE(p_location, '')
    || '|' || v_stamp
  );

  SELECT fs.post_ids, fs.scores INTO v_ids, v_scores
    FROM public.feed_sessions AS fs
   WHERE fs.user_id = v_uid AND fs.session_key = v_key
     AND fs.created_at > now() - INTERVAL '30 minutes';

  IF v_ids IS NULL THEN
    SELECT lower(home_city) INTO v_bucket
      FROM public.users WHERE user_id = v_uid;

    IF p_tribe_slug IS NOT NULL THEN
      SELECT t.tribe_id INTO v_tribe
        FROM public.tribes t WHERE t.slug = p_tribe_slug;
      IF v_tribe IS NULL THEN RETURN; END IF;
    END IF;

    WITH
    my_tribes AS (
      SELECT tm.tribe_id FROM public.tribe_members AS tm WHERE tm.user_id = v_uid
    ),
    my_friends AS (
      SELECT CASE WHEN f.user_a = v_uid THEN f.user_b ELSE f.user_a END AS friend_id
        FROM public.friendships AS f
       WHERE f.status = 'accepted' AND (f.user_a = v_uid OR f.user_b = v_uid)
    ),
    my_categories AS (
      SELECT DISTINCT p.category_name
        FROM public.post_likes AS l
        JOIN public.posts AS p ON p.post_id = l.post_id
       WHERE l.user_id = v_uid AND l.created_at > v_anchor - INTERVAL '30 days'
    ),
    my_people AS (
      SELECT p.feed_author_key AS author_id
        FROM public.post_likes AS l
        JOIN public.posts AS p ON p.post_id = l.post_id
       WHERE l.user_id = v_uid
         AND l.created_at > v_anchor - INTERVAL '30 days'
         AND p.feed_author_key <> v_uid
       GROUP BY p.feed_author_key ORDER BY count(*) DESC LIMIT 25
    ),
    quiet_posts AS (
      SELECT ni.post_id FROM public.post_not_interested AS ni WHERE ni.user_id = v_uid
    ),
    quiet_authors AS (
      SELECT ni.author_id FROM public.post_not_interested AS ni
       WHERE ni.user_id = v_uid AND ni.reason = 'author'
         AND ni.created_at > v_anchor - INTERVAL '90 days'
    ),
    quiet_topics AS (
      SELECT DISTINCT ni.category_name FROM public.post_not_interested AS ni
       WHERE ni.user_id = v_uid AND ni.reason = 'topic'
         AND ni.created_at > v_anchor - INTERVAL '90 days'
    ),
    cooled_authors AS (
      SELECT ni.author_id, count(*) AS n FROM public.post_not_interested AS ni
       WHERE ni.user_id = v_uid AND ni.reason = 'post'
         AND ni.created_at > v_anchor - INTERVAL '60 days'
       GROUP BY ni.author_id
    ),
    arm_fresh AS (
      SELECT p.post_id, p.feed_author_key AS author_id,
             p.display_author_id, p.persona_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
       WHERE p.created_at <= v_anchor AND p.deleted_at IS NULL
         AND p.is_story = FALSE
         AND (p.is_whisper = FALSE OR p.created_at > v_anchor - INTERVAL '24 hours')
         AND p.media_status <> 'blocked'
         AND (v_tribe IS NULL OR p.tribe_id = v_tribe)
         AND (p_category IS NULL OR p.category_name = p_category)
         AND (p_mood IS NULL OR p.post_mood = p_mood::public.mood_badge_type)
         AND (p_location IS NULL OR p.location_bucket = p_location)
       ORDER BY p.created_at DESC, p.post_id DESC
       LIMIT v_pool
    ),
    arm_popular AS (
      SELECT p.post_id, p.feed_author_key AS author_id,
             p.display_author_id, p.persona_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
       WHERE v_mode <> 'fresh' AND p.created_at <= v_anchor
         AND p.deleted_at IS NULL AND p.is_story = FALSE
         AND (p.is_whisper = FALSE OR p.created_at > v_anchor - INTERVAL '24 hours')
         AND p.media_status <> 'blocked'
         AND (v_tribe IS NULL OR p.tribe_id = v_tribe)
         AND (p_category IS NULL OR p.category_name = p_category)
         AND (p_mood IS NULL OR p.post_mood = p_mood::public.mood_badge_type)
         AND (p_location IS NULL OR p.location_bucket = p_location)
       ORDER BY (p.likes_count + p.comments_count) DESC, p.created_at DESC
       LIMIT GREATEST(200, v_pool / 3)
    ),
    arm_friends AS (
      SELECT p.post_id, p.feed_author_key AS author_id,
             p.display_author_id, p.persona_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
        JOIN my_friends AS mf ON mf.friend_id = p.display_author_id
       WHERE v_mode = 'foryou' AND p.created_at <= v_anchor
         AND p.created_at > v_anchor - INTERVAL '30 days'
         AND p.deleted_at IS NULL AND p.is_story = FALSE
         AND (p.is_whisper = FALSE OR p.created_at > v_anchor - INTERVAL '24 hours')
         AND p.media_status <> 'blocked'
         AND (v_tribe IS NULL OR p.tribe_id = v_tribe)
         AND (p_category IS NULL OR p.category_name = p_category)
         AND (p_mood IS NULL OR p.post_mood = p_mood::public.mood_badge_type)
       ORDER BY p.created_at DESC LIMIT 300
    ),
    arm_tribes AS (
      SELECT p.post_id, p.feed_author_key AS author_id,
             p.display_author_id, p.persona_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
        JOIN my_tribes AS mt ON mt.tribe_id = p.tribe_id
       WHERE v_mode = 'foryou' AND p.created_at <= v_anchor
         AND p.created_at > v_anchor - INTERVAL '30 days'
         AND p.deleted_at IS NULL AND p.is_story = FALSE
         AND (p.is_whisper = FALSE OR p.created_at > v_anchor - INTERVAL '24 hours')
         AND p.media_status <> 'blocked'
         AND (v_tribe IS NULL OR p.tribe_id = v_tribe)
         AND (p_category IS NULL OR p.category_name = p_category)
         AND (p_mood IS NULL OR p.post_mood = p_mood::public.mood_badge_type)
       ORDER BY p.created_at DESC LIMIT 300
    ),
    arm_people AS (
      SELECT p.post_id, p.feed_author_key AS author_id,
             p.display_author_id, p.persona_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
        JOIN my_people AS mp ON mp.author_id = p.feed_author_key
       WHERE v_mode = 'foryou' AND p.created_at <= v_anchor
         AND p.created_at > v_anchor - INTERVAL '30 days'
         AND p.deleted_at IS NULL AND p.is_story = FALSE
         AND (p.is_whisper = FALSE OR p.created_at > v_anchor - INTERVAL '24 hours')
         AND p.media_status <> 'blocked'
         AND (v_tribe IS NULL OR p.tribe_id = v_tribe)
         AND (p_category IS NULL OR p.category_name = p_category)
         AND (p_mood IS NULL OR p.post_mood = p_mood::public.mood_badge_type)
       ORDER BY p.created_at DESC LIMIT 200
    ),
    arm_topics AS (
      SELECT p.post_id, p.feed_author_key AS author_id,
             p.display_author_id, p.persona_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
       WHERE v_mode = 'foryou'
         AND p.category_name IN (SELECT category_name FROM my_categories)
         AND p.created_at <= v_anchor
         AND p.created_at > v_anchor - INTERVAL '14 days'
         AND p.deleted_at IS NULL AND p.is_story = FALSE
         AND (p.is_whisper = FALSE OR p.created_at > v_anchor - INTERVAL '24 hours')
         AND p.media_status <> 'blocked'
         AND (v_tribe IS NULL OR p.tribe_id = v_tribe)
         AND (p_mood IS NULL OR p.post_mood = p_mood::public.mood_badge_type)
         AND (p_location IS NULL OR p.location_bucket = p_location)
       ORDER BY p.created_at DESC LIMIT 200
    ),
    pool AS (
      SELECT DISTINCT ON (u.post_id) u.*
        FROM (
          SELECT * FROM arm_fresh
          UNION ALL SELECT * FROM arm_popular
          UNION ALL SELECT * FROM arm_friends
          UNION ALL SELECT * FROM arm_tribes
          UNION ALL SELECT * FROM arm_people
          UNION ALL SELECT * FROM arm_topics
        ) AS u
       ORDER BY u.post_id
    ),
    visible AS (
      SELECT v.* FROM pool AS v
       WHERE (
               CASE WHEN v.persona_id IS NULL
                    THEN EXISTS (
                           SELECT 1 FROM public.users AS au
                            WHERE au.user_id = v.display_author_id
                              AND au.created_at < v_anchor - INTERVAL '1 hour')
                    -- The account behind a persona is exactly what this
                    -- caller may not see, so the gate is asked on its behalf.
                    ELSE private.persona_owner_established(
                           v.persona_id, v_anchor - INTERVAL '1 hour')
               END)
         AND NOT EXISTS (
               SELECT 1 FROM public.post_likes AS ml
                WHERE ml.post_id = v.post_id AND ml.user_id = v_uid)
         AND NOT EXISTS (SELECT 1 FROM quiet_posts AS qp WHERE qp.post_id = v.post_id)
         AND NOT EXISTS (SELECT 1 FROM quiet_authors AS qa WHERE qa.author_id = v.author_id)
    ),
    scored AS (
      SELECT
        v.*,
        COALESCE(
          v.author_id IN (SELECT friend_id FROM my_friends)
          OR v.author_id IN (SELECT author_id FROM my_people)
          OR v.tribe_id IN (SELECT tribe_id FROM my_tribes)
          OR v.category_name IN (SELECT category_name FROM my_categories),
          FALSE
        ) AS is_affinity,
        CASE v_mode
          WHEN 'fresh' THEN EXTRACT(EPOCH FROM v.created_at)::DOUBLE PRECISION
          WHEN 'hot' THEN (
              0.6 * ln(1 + v.likes_count + 2 * v.comments_count)
              + 3.0 * exp(-LEAST(GREATEST(EXTRACT(EPOCH FROM (v_anchor - v.created_at)), 0) / 64800.0, 40.0)::DOUBLE PRECISION)
              - CASE WHEN si.seen_at IS NOT NULL THEN 1.5 ELSE 0 END
            )::DOUBLE PRECISION
          ELSE (
              0.6 * ln(1 + v.likes_count + 2 * v.comments_count)
              + 3.0 * exp(-LEAST(GREATEST(EXTRACT(EPOCH FROM (v_anchor - v.created_at)), 0) / 64800.0, 40.0)::DOUBLE PRECISION)
              + CASE WHEN v.author_id IN (SELECT friend_id FROM my_friends) THEN 2.2 ELSE 0 END
              + CASE WHEN v.author_id IN (SELECT author_id FROM my_people) THEN 1.4 ELSE 0 END
              + CASE WHEN v.tribe_id IN (SELECT tribe_id FROM my_tribes) THEN 1.2 ELSE 0 END
              + CASE WHEN v.category_name IN (SELECT category_name FROM my_categories) THEN 0.6 ELSE 0 END
              + CASE WHEN v_bucket IS NOT NULL AND v.location_bucket = v_bucket THEN 0.4 ELSE 0 END
              - CASE WHEN v.comments_count > v.likes_count * 4 THEN 0.5 ELSE 0 END
              - CASE WHEN si.seen_at IS NOT NULL
                     THEN 2.5 * exp(-LEAST(GREATEST(EXTRACT(EPOCH FROM (v_anchor - si.seen_at)), 0) / 259200.0, 40.0)::DOUBLE PRECISION)
                     ELSE 0 END
              - COALESCE((SELECT LEAST(ca.n, 4) * 0.75 FROM cooled_authors AS ca
                           WHERE ca.author_id = v.author_id), 0)
              - CASE WHEN v.category_name IN (SELECT category_name FROM quiet_topics) THEN 1.5 ELSE 0 END
              -- Seeded on the anchor, not the calendar day. Every page of one
              -- session shares an anchor, so pagination is as stable as it
              -- was; a pull-to-refresh mints a new one, so near-ties come back
              -- in a different order instead of the identical feed until
              -- midnight.
              + (((hashtextextended(v_uid::TEXT || v.post_id::TEXT || v_stamp, 0) & 1023)::DOUBLE PRECISION / 1023.0) - 0.5) * 0.7
            )::DOUBLE PRECISION
        END AS base_score
      FROM visible AS v
      LEFT JOIN public.post_impressions AS si
        ON si.post_id = v.post_id AND si.user_id = v_uid
    ),
    deduped AS (
      SELECT s.*, (
        s.base_score
        - CASE WHEN v_mode = 'fresh' THEN 0 ELSE
            (ROW_NUMBER() OVER (PARTITION BY s.author_id ORDER BY s.base_score DESC, s.post_id) - 1) * 0.7
          END
      )::DOUBLE PRECISION AS final_score
      FROM scored AS s
    ),
    ordered AS (
      SELECT d.*,
        ROW_NUMBER() OVER (ORDER BY d.final_score DESC, d.created_at DESC, d.post_id DESC) AS rn,
        ROW_NUMBER() OVER (PARTITION BY (v_mode <> 'foryou' OR d.is_affinity)
                           ORDER BY d.final_score DESC, d.created_at DESC, d.post_id DESC) AS arm_rn
      FROM deduped AS d
    ),
    slotted AS (
      SELECT o.*,
        CASE WHEN (v_mode <> 'foryou' OR o.is_affinity)
             THEN ((o.arm_rn - 1) / 8) * 10 + ((o.arm_rn - 1) % 8) + 1
             ELSE ((o.arm_rn - 1) / 2) * 10 + 8 + ((o.arm_rn - 1) % 2) + 1
        END AS slot
      FROM ordered AS o
    ),
    placed AS (
      SELECT s.post_id, s.final_score,
             (ROW_NUMBER() OVER (ORDER BY s.slot, s.rn))::INTEGER AS fpos
      FROM slotted AS s
    ),
    kept AS (
      SELECT pd.post_id, pd.final_score, pd.fpos
        FROM placed AS pd ORDER BY pd.fpos LIMIT 400
    )
    SELECT array_agg(k.post_id ORDER BY k.fpos),
           array_agg(k.final_score ORDER BY k.fpos)
      INTO v_ids, v_scores
      FROM kept AS k;

    v_ids := COALESCE(v_ids, ARRAY[]::UUID[]);
    v_scores := COALESCE(v_scores, ARRAY[]::DOUBLE PRECISION[]);

    INSERT INTO public.feed_sessions AS fs
      (user_id, session_key, post_ids, scores, created_at)
    VALUES (v_uid, v_key, v_ids, v_scores, now())
    ON CONFLICT (user_id, session_key) DO UPDATE
      SET post_ids = EXCLUDED.post_ids, scores = EXCLUDED.scores, created_at = now();
  END IF;

  RETURN QUERY
  SELECT f.post_id, f.author_id, f.author_pseudonym, f.author_avatar_seed,
    f.author_profile_photo_url, f.author_is_verified, f.author_karma,
    f.tribe_name, f.tribe_slug, f.tribe_id, f.category_name, f.post_type,
    f.content, f.post_mood, f.is_whisper, f.location_bucket, f.likes_count,
    f.comments_count, f.view_count, f.image_url, f.audio_url,
    f.audio_duration_seconds, f.crisis_level, f.created_at, f.deleted_at,
    v_scores[v_after + s.ord], f.music_track_id, f.music_start_ms,
    f.music_duration_ms, f.music_volume, f.goal_reached_at, f.media_status,
    f.card_background_color, f.card_text_color, f.is_story, f.story_audience,
    (v_after + s.ord)::INTEGER, v_anchor
  FROM unnest(v_ids[(v_after + 1):(v_after + v_limit)])
         WITH ORDINALITY AS s(post_id, ord)
  JOIN public.feed_posts AS f ON f.post_id = s.post_id
  WHERE f.deleted_at IS NULL
    AND (f.is_whisper = FALSE OR f.created_at > now() - INTERVAL '24 hours')
  ORDER BY s.ord;
END;
$function$;

SELECT public.record_migration('20261078090000', 'the_ranker_learns_the_new_name');

NOTIFY pgrst, 'reload schema';
