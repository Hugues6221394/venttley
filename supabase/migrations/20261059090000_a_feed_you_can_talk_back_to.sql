-- A feed you can talk back to.
--
-- Until now the only thing a reader could say about a post was a hug or
-- silence, and silence had to stand in for "I have read this", "this is not
-- for me" and "please stop showing me this person". Three different things
-- ranked as one.
--
-- This adds the missing sentence — Not interested, and Show less from this
-- person — and two things that follow from it: a candidate pool built out of
-- what a particular reader actually reads, and a cache so that saying it does
-- not cost a re-rank on every page.

------------------------------------------------------------------------------
-- 1. Not interested.
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.post_not_interested (
  user_id       UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  post_id       UUID NOT NULL REFERENCES public.posts(post_id) ON DELETE CASCADE,
  -- Denormalised so the feed can act on the signal without joining back to a
  -- post that may since have been deleted.
  author_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  category_name VARCHAR(64),
  reason        TEXT NOT NULL DEFAULT 'post'
                CHECK (reason IN ('post', 'author', 'topic')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, post_id)
);

COMMENT ON TABLE public.post_not_interested IS
  'What a reader has explicitly asked to see less of. "post" hides that one '
  'post; "author" quiets that person for ninety days; "topic" weighs down a '
  'category. Reversible — nothing here is a block.';

CREATE INDEX IF NOT EXISTS post_not_interested_author_idx
  ON public.post_not_interested (user_id, author_id, created_at DESC);

ALTER TABLE public.post_not_interested ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "not interested own read" ON public.post_not_interested;
DROP POLICY IF EXISTS "not interested own rows" ON public.post_not_interested;
CREATE POLICY "not interested own rows"
  ON public.post_not_interested FOR ALL
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

REVOKE ALL ON public.post_not_interested FROM PUBLIC, anon, authenticated;
-- The RPCs below run as the caller, so they write through this policy rather
-- than around it. Which is the point: the check for "am I allowed to see this
-- post at all" is then row level security's, not a second copy of it.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.post_not_interested TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.post_not_interested TO service_role;

------------------------------------------------------------------------------
-- 2. The page cache.
------------------------------------------------------------------------------
-- Ranking a page costs about thirty milliseconds; most feed requests are the
-- second, third and fourth page of a session that has already paid for it.
-- The ranked order is kept for half an hour against the anchor the client is
-- already echoing back, and the rows themselves are still fetched through the
-- view, so row level security decides what a cached position actually shows.
-- A post deleted, hidden or blocked after the ranking simply does not come
-- back.
CREATE TABLE IF NOT EXISTS public.feed_sessions (
  user_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  session_key TEXT NOT NULL,
  post_ids    UUID[] NOT NULL,
  scores      DOUBLE PRECISION[] NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, session_key)
);

CREATE INDEX IF NOT EXISTS feed_sessions_created_idx
  ON public.feed_sessions (created_at);

ALTER TABLE public.feed_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "feed sessions own" ON public.feed_sessions;
CREATE POLICY "feed sessions own"
  ON public.feed_sessions FOR ALL
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

REVOKE ALL ON public.feed_sessions FROM PUBLIC, anon, authenticated;
-- The feed runs as the caller and writes its own row; the policy above is what
-- stops it being anybody else's.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.feed_sessions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.feed_sessions TO service_role;

------------------------------------------------------------------------------
-- 3. Saying it.
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_not_interested(
  p_post_id UUID,
  p_reason  TEXT DEFAULT 'post'
)
RETURNS BOOLEAN
LANGUAGE plpgsql
-- SECURITY INVOKER on purpose. As a definer this reads feed_posts as
-- postgres, which bypasses row level security, and a reader could mark a post
-- inside a private tribe they have never joined -- learning it exists.
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me       UUID := (SELECT auth.uid());
  v_author   UUID;
  v_category VARCHAR(64);
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF p_reason NOT IN ('post', 'author', 'topic') THEN
    RAISE EXCEPTION 'invalid_reason';
  END IF;

  -- Read through the view as the caller: you can only say this about a post
  -- you were allowed to see in the first place.
  SELECT f.author_id, f.category_name INTO v_author, v_category
    FROM public.feed_posts AS f
   WHERE f.post_id = p_post_id;

  IF v_author IS NULL THEN RAISE EXCEPTION 'post_not_found'; END IF;
  IF v_author = v_me THEN RAISE EXCEPTION 'that_is_your_own_post'; END IF;

  INSERT INTO public.post_not_interested
    (user_id, post_id, author_id, category_name, reason)
  VALUES (v_me, p_post_id, v_author, v_category, p_reason)
  ON CONFLICT (user_id, post_id) DO UPDATE
    SET reason = EXCLUDED.reason, created_at = now();

  -- The point of saying it is that the post goes away now, not at the next
  -- refresh, so the cached ranking for this reader is dropped.
  DELETE FROM public.feed_sessions WHERE user_id = v_me;

  RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.mark_not_interested(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_not_interested(UUID, TEXT)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.undo_not_interested(p_post_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
-- SECURITY INVOKER on purpose. As a definer this reads feed_posts as
-- postgres, which bypasses row level security, and a reader could mark a post
-- inside a private tribe they have never joined -- learning it exists.
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_n  INTEGER;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  DELETE FROM public.post_not_interested
   WHERE user_id = v_me AND post_id = p_post_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  DELETE FROM public.feed_sessions WHERE user_id = v_me;
  RETURN v_n > 0;
END $$;

REVOKE ALL ON FUNCTION public.undo_not_interested(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.undo_not_interested(UUID)
  TO authenticated, service_role;

------------------------------------------------------------------------------
-- 4. Housekeeping.
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prune_feed_sessions()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_n INTEGER;
BEGIN
  DELETE FROM public.feed_sessions WHERE created_at < now() - INTERVAL '2 hours';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION public.prune_feed_sessions() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prune_feed_sessions() TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('prune_feed_sessions_hourly')
      WHERE EXISTS (
        SELECT 1 FROM cron.job WHERE jobname = 'prune_feed_sessions_hourly'
      );
    PERFORM cron.schedule(
      'prune_feed_sessions_hourly',
      '23 * * * *',
      'SELECT public.prune_feed_sessions()'
    );
  END IF;
END $$;

-- Two arms below read the people and the topics a reader actually engages
-- with. Without this the planner has to sort every like a person has ever
-- given to find the recent ones.
CREATE INDEX IF NOT EXISTS post_likes_user_created_idx
  ON public.post_likes (user_id, created_at DESC);

------------------------------------------------------------------------------
-- 5. The feed, listening.
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.personal_feed(
  p_limit          INT DEFAULT 20,
  p_mode           TEXT DEFAULT 'foryou',
  p_anchor         TIMESTAMPTZ DEFAULT NULL,
  p_after_position INT DEFAULT NULL,
  p_category       TEXT DEFAULT NULL,
  p_mood           TEXT DEFAULT NULL,
  p_tribe_slug     TEXT DEFAULT NULL,
  p_location       TEXT DEFAULT NULL
)
RETURNS TABLE (
  post_id UUID,
  author_id UUID,
  author_pseudonym TEXT,
  author_avatar_seed CHARACTER VARYING,
  author_profile_photo_url TEXT,
  author_is_verified BOOLEAN,
  author_karma INTEGER,
  tribe_name CHARACTER VARYING,
  tribe_slug TEXT,
  tribe_id UUID,
  category_name CHARACTER VARYING,
  post_type CHARACTER VARYING,
  content TEXT,
  post_mood public.mood_badge_type,
  is_whisper BOOLEAN,
  location_bucket TEXT,
  likes_count INTEGER,
  comments_count INTEGER,
  view_count INTEGER,
  image_url TEXT,
  audio_url TEXT,
  audio_duration_seconds INTEGER,
  crisis_level TEXT,
  created_at TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ,
  personal_score DOUBLE PRECISION,
  music_track_id UUID,
  music_start_ms INTEGER,
  music_duration_ms INTEGER,
  music_volume REAL,
  goal_reached_at TIMESTAMPTZ,
  media_status TEXT,
  card_background_color TEXT,
  card_text_color TEXT,
  is_story BOOLEAN,
  story_audience TEXT,
  feed_position INTEGER,
  feed_anchor TIMESTAMPTZ
)
LANGUAGE plpgsql
-- VOLATILE because it writes its own page cache. Still SECURITY INVOKER:
-- everything below is readable only because row level security says the
-- caller may read it. Do not make this SECURITY DEFINER to make it faster.
VOLATILE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  v_uid    UUID := (SELECT auth.uid());
  v_bucket TEXT;
  v_tribe  UUID;
  -- clock_timestamp(), not now(): now() is the transaction timestamp, so two
  -- feed calls inside one transaction would share a cache key and the second
  -- would be served the first one's ranking.
  v_anchor TIMESTAMPTZ := COALESCE(p_anchor, clock_timestamp());
  v_limit  INT := GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
  v_after  INT := GREATEST(0, COALESCE(p_after_position, 0));
  v_pool   INT;
  v_mode   TEXT := COALESCE(p_mode, 'foryou');
  v_key    TEXT;
  v_ids    UUID[];
  v_scores DOUBLE PRECISION[];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF v_mode NOT IN ('foryou', 'hot', 'fresh') THEN
    RAISE EXCEPTION 'invalid_mode';
  END IF;

  v_pool := LEAST(1200, GREATEST(400, (v_after + v_limit) * 4));

  v_key := md5(
    v_mode || '|' || COALESCE(p_category, '') || '|' || COALESCE(p_mood, '')
    || '|' || COALESCE(p_tribe_slug, '') || '|' || COALESCE(p_location, '')
    || '|' || to_char(v_anchor AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US')
  );

  SELECT fs.post_ids, fs.scores INTO v_ids, v_scores
    FROM public.feed_sessions AS fs
   WHERE fs.user_id = v_uid
     AND fs.session_key = v_key
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
      -- friendships stores the pair ordered (user_a < user_b), so membership
      -- has to be checked from both ends and the friend is whichever one is
      -- not me.
      SELECT CASE WHEN f.user_a = v_uid THEN f.user_b ELSE f.user_a END AS friend_id
        FROM public.friendships AS f
       WHERE f.status = 'accepted'
         AND (f.user_a = v_uid OR f.user_b = v_uid)
    ),
    my_categories AS (
      SELECT DISTINCT p.category_name
        FROM public.post_likes AS l
        JOIN public.posts AS p ON p.post_id = l.post_id
       WHERE l.user_id = v_uid
         AND l.created_at > v_anchor - INTERVAL '30 days'
    ),
    -- Not your friends: the people you actually read. A pool assembled only
    -- from friends, tribes and global popularity is the same pool for
    -- everybody who has not joined anything.
    my_people AS (
      SELECT p.author_id
        FROM public.post_likes AS l
        JOIN public.posts AS p ON p.post_id = l.post_id
       WHERE l.user_id = v_uid
         AND l.created_at > v_anchor - INTERVAL '30 days'
         AND p.author_id <> v_uid
       GROUP BY p.author_id
       ORDER BY count(*) DESC
       LIMIT 25
    ),
    -- What you have asked to see less of.
    quiet_posts AS (
      SELECT ni.post_id FROM public.post_not_interested AS ni
       WHERE ni.user_id = v_uid
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
    -- Saying it once about one post is about the post. Saying it four times
    -- about one person is about the person, whether or not they ever pressed
    -- the other button.
    cooled_authors AS (
      SELECT ni.author_id, count(*) AS n
        FROM public.post_not_interested AS ni
       WHERE ni.user_id = v_uid AND ni.reason = 'post'
         AND ni.created_at > v_anchor - INTERVAL '60 days'
       GROUP BY ni.author_id
    ),
    ---------------------------------------------------------------------------
    -- The candidate pool. Six bounded arms instead of one unbounded scan.
    -- Each arm is an index walk with a LIMIT, so row level security is only
    -- evaluated on the rows actually taken rather than on every post ever
    -- written. Everything is anchored at v_anchor, which the client echoes
    -- back with its cursor, so the pool a reader is paging through does not
    -- shift under them when somebody posts.
    ---------------------------------------------------------------------------
    arm_fresh AS (
      SELECT p.post_id, p.author_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
       WHERE p.created_at <= v_anchor
         AND p.deleted_at IS NULL
         AND p.is_story = FALSE
         AND (p.is_whisper = FALSE OR p.created_at > v_anchor - INTERVAL '24 hours')
         -- Blocked media never reaches a feed, whatever else it scores. The
         -- scanner's verdict is not advisory.
         AND p.media_status <> 'blocked'
         AND (v_tribe IS NULL OR p.tribe_id = v_tribe)
         AND (p_category IS NULL OR p.category_name = p_category)
         AND (p_mood IS NULL OR p.post_mood = p_mood::public.mood_badge_type)
         AND (p_location IS NULL OR p.location_bucket = p_location)
       ORDER BY p.created_at DESC, p.post_id DESC
       LIMIT v_pool
    ),
    arm_popular AS (
      SELECT p.post_id, p.author_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
       WHERE v_mode <> 'fresh'
         AND p.created_at <= v_anchor
         AND p.deleted_at IS NULL
         AND p.is_story = FALSE
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
      SELECT p.post_id, p.author_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
        JOIN my_friends AS mf ON mf.friend_id = p.author_id
       WHERE v_mode = 'foryou'
         AND p.created_at <= v_anchor
         AND p.created_at > v_anchor - INTERVAL '30 days'
         AND p.deleted_at IS NULL
         AND p.is_story = FALSE
         AND (p.is_whisper = FALSE OR p.created_at > v_anchor - INTERVAL '24 hours')
         AND p.media_status <> 'blocked'
         AND (v_tribe IS NULL OR p.tribe_id = v_tribe)
         AND (p_category IS NULL OR p.category_name = p_category)
         AND (p_mood IS NULL OR p.post_mood = p_mood::public.mood_badge_type)
       ORDER BY p.created_at DESC
       LIMIT 300
    ),
    arm_tribes AS (
      SELECT p.post_id, p.author_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
        JOIN my_tribes AS mt ON mt.tribe_id = p.tribe_id
       WHERE v_mode = 'foryou'
         AND p.created_at <= v_anchor
         AND p.created_at > v_anchor - INTERVAL '30 days'
         AND p.deleted_at IS NULL
         AND p.is_story = FALSE
         AND (p.is_whisper = FALSE OR p.created_at > v_anchor - INTERVAL '24 hours')
         AND p.media_status <> 'blocked'
         AND (v_tribe IS NULL OR p.tribe_id = v_tribe)
         AND (p_category IS NULL OR p.category_name = p_category)
         AND (p_mood IS NULL OR p.post_mood = p_mood::public.mood_badge_type)
       ORDER BY p.created_at DESC
       LIMIT 300
    ),
    arm_people AS (
      SELECT p.post_id, p.author_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
        JOIN my_people AS mp ON mp.author_id = p.author_id
       WHERE v_mode = 'foryou'
         AND p.created_at <= v_anchor
         AND p.created_at > v_anchor - INTERVAL '30 days'
         AND p.deleted_at IS NULL
         AND p.is_story = FALSE
         AND (p.is_whisper = FALSE OR p.created_at > v_anchor - INTERVAL '24 hours')
         AND p.media_status <> 'blocked'
         AND (v_tribe IS NULL OR p.tribe_id = v_tribe)
         AND (p_category IS NULL OR p.category_name = p_category)
         AND (p_mood IS NULL OR p.post_mood = p_mood::public.mood_badge_type)
       ORDER BY p.created_at DESC
       LIMIT 200
    ),
    arm_topics AS (
      SELECT p.post_id, p.author_id, p.tribe_id, p.category_name,
             p.location_bucket, p.likes_count, p.comments_count, p.created_at
        FROM public.posts AS p
       WHERE v_mode = 'foryou'
         AND p.category_name IN (SELECT category_name FROM my_categories)
         AND p.created_at <= v_anchor
         AND p.created_at > v_anchor - INTERVAL '14 days'
         AND p.deleted_at IS NULL
         AND p.is_story = FALSE
         AND (p.is_whisper = FALSE OR p.created_at > v_anchor - INTERVAL '24 hours')
         AND p.media_status <> 'blocked'
         AND (v_tribe IS NULL OR p.tribe_id = v_tribe)
         AND (p_mood IS NULL OR p.post_mood = p_mood::public.mood_badge_type)
         AND (p_location IS NULL OR p.location_bucket = p_location)
       ORDER BY p.created_at DESC
       LIMIT 200
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
    -- Ranking needs eight columns off the post; the forty a card is drawn
    -- from are fetched at the end, for the rows actually being returned.
    visible AS (
      SELECT v.*
        FROM pool AS v
       WHERE
         -- An account minutes old posting into a national feed is a spammer
         -- often enough to be worth the hour.
         EXISTS (
           SELECT 1 FROM public.users AS au
            WHERE au.user_id = v.author_id
              AND au.created_at < v_anchor - INTERVAL '1 hour'
         )
         -- Already liked: you have seen it and acted on it. Keeping it in
         -- competes with posts you have not seen.
         AND NOT EXISTS (
           SELECT 1 FROM public.post_likes AS ml
            WHERE ml.post_id = v.post_id AND ml.user_id = v_uid
         )
         -- You said so.
         AND NOT EXISTS (
           SELECT 1 FROM quiet_posts AS qp WHERE qp.post_id = v.post_id
         )
         AND NOT EXISTS (
           SELECT 1 FROM quiet_authors AS qa WHERE qa.author_id = v.author_id
         )
    ),
    scored AS (
      SELECT
        v.*,
        -- COALESCE, not bare OR: a post with no tribe tested against a
        -- non-empty tribe list yields NULL, and a NULL here would open a
        -- third partition below and hand out twice the reserved slots.
        COALESCE(
          v.author_id IN (SELECT friend_id FROM my_friends)
          OR v.author_id IN (SELECT author_id FROM my_people)
          OR v.tribe_id IN (SELECT tribe_id FROM my_tribes)
          OR v.category_name IN (SELECT category_name FROM my_categories),
          FALSE
        ) AS is_affinity,
        CASE v_mode
          WHEN 'fresh' THEN
            EXTRACT(EPOCH FROM v.created_at)::DOUBLE PRECISION
          WHEN 'hot' THEN
            (
              0.6 * ln(1 + v.likes_count + 2 * v.comments_count)
              + 3.0 * exp(
                  -LEAST(
                    GREATEST(
                      EXTRACT(EPOCH FROM (v_anchor - v.created_at)), 0
                    ) / 64800.0,
                    40.0
                  )::DOUBLE PRECISION
                )
              - CASE WHEN si.seen_at IS NOT NULL THEN 1.5 ELSE 0 END
            )::DOUBLE PRECISION
          ELSE
            (
              -- Quality. A comment costs more to write than a tap, so it
              -- counts for more, and the logarithm keeps a runaway post from
              -- owning every feed in the country.
              0.6 * ln(1 + v.likes_count + 2 * v.comments_count)
              -- Recency as a decay, not a ramp. Age can only ever cost a
              -- post, and the cost flattens: half of this term is gone in
              -- about half a day, so a post with a hundred hugs from this
              -- morning still beats an empty post from an hour ago.
              + 3.0 * exp(
                  -LEAST(
                    GREATEST(
                      EXTRACT(EPOCH FROM (v_anchor - v.created_at)), 0
                    ) / 64800.0,
                    -- Clamped, and this is not decoration: exp() of a numeric
                    -- that far below zero underflows out of double precision
                    -- and raises, which a two-year-old post in the pool will
                    -- do on the first page it appears in.
                    40.0
                  )::DOUBLE PRECISION
                )
              -- Affinity. Being friends is the most explicit statement
              -- someone makes about whose posts they want, so it is the
              -- strongest of these — worth roughly thirty-five reactions.
              + CASE WHEN v.author_id IN (SELECT friend_id FROM my_friends)
                     THEN 2.2 ELSE 0 END
              + CASE WHEN v.author_id IN (SELECT author_id FROM my_people)
                     THEN 1.4 ELSE 0 END
              + CASE WHEN v.tribe_id IN (SELECT tribe_id FROM my_tribes)
                     THEN 1.2 ELSE 0 END
              + CASE WHEN v.category_name IN (SELECT category_name FROM my_categories)
                     THEN 0.6 ELSE 0 END
              + CASE WHEN v_bucket IS NOT NULL AND v.location_bucket = v_bucket
                     THEN 0.4 ELSE 0 END
              -- A pile-on reads as an argument, not a conversation.
              - CASE WHEN v.comments_count > v.likes_count * 4
                     THEN 0.5 ELSE 0 END
              -- Already seen, and the demotion fades over about three days,
              -- so a post you scrolled past this morning drops out of today's
              -- feed without being banished from next week's.
              - CASE WHEN si.seen_at IS NOT NULL
                     THEN 2.5 * exp(
                       -LEAST(
                         GREATEST(
                           EXTRACT(EPOCH FROM (v_anchor - si.seen_at)), 0
                         ) / 259200.0,
                         40.0
                       )::DOUBLE PRECISION
                     )
                     ELSE 0 END
              -- You have said "not interested" about this person before.
              - COALESCE(
                  (SELECT LEAST(ca.n, 4) * 0.75
                     FROM cooled_authors AS ca
                    WHERE ca.author_id = v.author_id),
                  0
                )
              - CASE WHEN v.category_name IN (SELECT category_name FROM quiet_topics)
                     THEN 1.5 ELSE 0 END
              -- A little noise, deterministically: the same reader gets the
              -- same shuffle all day, so pagination still lines up, and a
              -- different one tomorrow. Enough to break ties, not enough to
              -- promote a bad post over a good one.
              + (
                  (
                    (
                      hashtextextended(
                        v_uid::TEXT || v.post_id::TEXT
                          || to_char(v_anchor, 'YYYY-MM-DD'),
                        0
                      ) & 1023
                    )::DOUBLE PRECISION / 1023.0
                  ) - 0.5
                ) * 0.5
            )::DOUBLE PRECISION
        END AS base_score
      FROM visible AS v
      LEFT JOIN public.post_impressions AS si
        ON si.post_id = v.post_id AND si.user_id = v_uid
    ),
    deduped AS (
      SELECT
        s.*,
        (
          s.base_score
          -- Author diversity. The nth-best post by an author the feed has
          -- already shown is penalised, so one prolific poster cannot own the
          -- page. Computed over the whole pool rather than the page so a
          -- post's score does not change as you scroll. Never applied to
          -- Fresh, which has to stay strictly chronological.
          - CASE WHEN v_mode = 'fresh' THEN 0 ELSE
              (
                ROW_NUMBER() OVER (
                  PARTITION BY s.author_id ORDER BY s.base_score DESC, s.post_id
                ) - 1
              ) * 0.7
            END
        )::DOUBLE PRECISION AS final_score
      FROM scored AS s
    ),
    ordered AS (
      SELECT
        d.*,
        ROW_NUMBER() OVER (
          ORDER BY d.final_score DESC, d.created_at DESC, d.post_id DESC
        ) AS rn,
        ROW_NUMBER() OVER (
          PARTITION BY (v_mode <> 'foryou' OR d.is_affinity)
          ORDER BY d.final_score DESC, d.created_at DESC, d.post_id DESC
        ) AS arm_rn
      FROM deduped AS d
    ),
    slotted AS (
      SELECT
        o.*,
        -- Two slots in every ten are held for something outside your tribes,
        -- your friends and the categories you already like. A feed that only
        -- ever confirms what it already knows about you stops being a feed.
        -- When one side runs out the other closes the gap, because positions
        -- are renumbered below rather than used directly.
        CASE WHEN (v_mode <> 'foryou' OR o.is_affinity)
             THEN ((o.arm_rn - 1) / 8) * 10 + ((o.arm_rn - 1) % 8) + 1
             ELSE ((o.arm_rn - 1) / 2) * 10 + 8 + ((o.arm_rn - 1) % 2) + 1
        END AS slot
      FROM ordered AS o
    ),
    placed AS (
      SELECT
        s.post_id,
        s.final_score,
        (ROW_NUMBER() OVER (ORDER BY s.slot, s.rn))::INTEGER AS fpos
      FROM slotted AS s
    ),
    kept AS (
      SELECT pd.post_id, pd.final_score, pd.fpos
        FROM placed AS pd
       ORDER BY pd.fpos
       LIMIT 400
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
      SET post_ids = EXCLUDED.post_ids,
          scores = EXCLUDED.scores,
          created_at = now();
  END IF;

  RETURN QUERY
  SELECT
    f.post_id,
    f.author_id,
    f.author_pseudonym,
    f.author_avatar_seed,
    f.author_profile_photo_url,
    f.author_is_verified,
    f.author_karma,
    f.tribe_name,
    f.tribe_slug,
    f.tribe_id,
    f.category_name,
    f.post_type,
    f.content,
    f.post_mood,
    f.is_whisper,
    f.location_bucket,
    f.likes_count,
    f.comments_count,
    f.view_count,
    f.image_url,
    f.audio_url,
    f.audio_duration_seconds,
    f.crisis_level,
    f.created_at,
    f.deleted_at,
    v_scores[v_after + s.ord],
    f.music_track_id,
    f.music_start_ms,
    f.music_duration_ms,
    f.music_volume,
    f.goal_reached_at,
    f.media_status,
    f.card_background_color,
    f.card_text_color,
    f.is_story,
    f.story_audience,
    (v_after + s.ord)::INTEGER,
    v_anchor
  -- The rows are fetched through the view every time, cache or no cache, so
  -- a post deleted, hidden or blocked since the ranking does not come back.
  FROM unnest(v_ids[(v_after + 1):(v_after + v_limit)])
         WITH ORDINALITY AS s(post_id, ord)
  JOIN public.feed_posts AS f ON f.post_id = s.post_id
  WHERE f.deleted_at IS NULL
    AND (f.is_whisper = FALSE OR f.created_at > now() - INTERVAL '24 hours')
  ORDER BY s.ord;
END;
$$;

REVOKE ALL ON FUNCTION public.personal_feed(
  INT, TEXT, TIMESTAMPTZ, INT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.personal_feed(
  INT, TEXT, TIMESTAMPTZ, INT, TEXT, TEXT, TEXT, TEXT
) TO authenticated, service_role;

SELECT public.record_migration(
  '20261059090000', 'a_feed_you_can_talk_back_to'
);

NOTIFY pgrst, 'reload schema';
