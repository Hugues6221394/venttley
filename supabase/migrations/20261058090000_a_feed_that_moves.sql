-- A feed that moves.
--
-- Three things were wrong with the feed, and the first two are not about
-- ranking at all.
--
-- 1. personal_feed ran SECURITY DEFINER as postgres, which carries BYPASSRLS.
--    Row level security on posts — the rule that keeps private tribes private,
--    hidden posts hidden and unapproved posts unpublished — was simply not
--    being applied to the For You feed. The only filter that survived was the
--    author check inside the feed_posts view. A stranger's For You feed could
--    contain a post written inside a private tribe they had never joined.
--    Verified before this migration: a private-tribe post, a moderator-hidden
--    post and an unapproved post all appeared through personal_feed, and none
--    of them appeared when the same account read feed_posts directly.
--
-- 2. feed_hot — the Hot sort, and the cold-start fallback every brand new
--    account lands on — has been returning "permission denied for materialized
--    view mv_hot_posts" to every client since the view's backing cache was
--    revoked from authenticated. feed_hot is security_invoker, so it reads the
--    cache as the caller, and the caller has no rights to it.
--
-- 3. The ranking itself. Age was added to the score at a rate of roughly two
--    points a day with no upper bound, so on a long enough timeline the newest
--    post always won regardless of what was in it; the candidate set was every
--    post ever written, scanned in full on every page (3.2 seconds at 200k
--    posts on this data); nothing recorded what a reader had already been
--    shown, so two consecutive opens returned the same twenty posts.
--
-- What follows fixes all three. The feed is one function now, serving all
-- three sorts, running as the caller so that row level security is the only
-- thing deciding what is visible, over a bounded candidate pool.

------------------------------------------------------------------------------
-- 1. A block is a visibility rule, not a feed rule.
------------------------------------------------------------------------------
-- The old feed filtered blocked authors in its own CTE. Running as the caller
-- it no longer can: user_blocks only exposes rows where you are the blocker,
-- so "somebody blocked me" is invisible to an invoker query. That filter
-- belongs one level down anyway — in the helper row level security already
-- calls for every post read, so a block hides the post everywhere it appears
-- rather than only in the feed.
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
    OR (
      COALESCE(
        (
          SELECT u.shadow_banned IS NOT TRUE
                 AND u.deactivated_at IS NULL
            FROM public.users u
           WHERE u.user_id = p_author_id
        ),
        TRUE
      )
      AND NOT EXISTS (
        SELECT 1
          FROM public.user_blocks b
         WHERE (
                 b.blocker_id = (SELECT auth.uid())
                 AND b.blocked_id = p_author_id
               )
            OR (
                 b.blocked_id = (SELECT auth.uid())
                 AND b.blocker_id = p_author_id
               )
      )
    );
$$;

------------------------------------------------------------------------------
-- 2. What a reader has already been shown.
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.post_impressions (
  user_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  post_id     UUID NOT NULL REFERENCES public.posts(post_id) ON DELETE CASCADE,
  seen_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  seen_count  INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (user_id, post_id)
);

COMMENT ON TABLE public.post_impressions IS
  'One row per reader per post they have actually had on screen. Feeds demote '
  'these rather than hiding them, and rows older than 30 days are pruned.';

CREATE INDEX IF NOT EXISTS post_impressions_user_seen_idx
  ON public.post_impressions (user_id, seen_at DESC);

ALTER TABLE public.post_impressions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "post impressions own read" ON public.post_impressions;
CREATE POLICY "post impressions own read"
  ON public.post_impressions FOR SELECT
  USING (user_id = (SELECT auth.uid()));

REVOKE ALL ON public.post_impressions FROM PUBLIC, anon, authenticated;
-- Read only: the feed reads your own rows as you. Writes go through the RPC
-- below, so a client cannot claim to have seen somebody else's feed.
GRANT SELECT ON public.post_impressions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.post_impressions TO service_role;

CREATE OR REPLACE FUNCTION public.note_post_impressions(p_ids UUID[])
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_n  INTEGER;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN RETURN 0; END IF;

  INSERT INTO public.post_impressions AS pi (user_id, post_id, seen_at)
  -- Capped, like note_discovery_impressions, so a looping client cannot write
  -- unbounded rows.
  SELECT v_me, id, now()
    FROM unnest(p_ids[1:200]) AS id
   WHERE EXISTS (SELECT 1 FROM public.posts p WHERE p.post_id = id)
  ON CONFLICT (user_id, post_id) DO UPDATE
    SET seen_at = now(),
        seen_count = pi.seen_count + 1;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION public.note_post_impressions(UUID[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.note_post_impressions(UUID[])
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prune_post_impressions()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_n INTEGER;
BEGIN
  DELETE FROM public.post_impressions
   WHERE seen_at < now() - INTERVAL '30 days';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION public.prune_post_impressions() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prune_post_impressions() TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('prune_post_impressions_daily')
      WHERE EXISTS (
        SELECT 1 FROM cron.job WHERE jobname = 'prune_post_impressions_daily'
      );
    PERFORM cron.schedule(
      'prune_post_impressions_daily',
      '45 3 * * *',
      'SELECT public.prune_post_impressions()'
    );
  END IF;
END $$;

------------------------------------------------------------------------------
-- 3. An index for the one ordering the feed did not have.
------------------------------------------------------------------------------
-- The candidate pool draws a "most engaged" arm. Without this the arm is a
-- sort of the whole table; with it, it is an index walk that stops as soon as
-- it has enough rows the caller is allowed to see.
CREATE INDEX IF NOT EXISTS posts_engagement_idx
  ON public.posts (((likes_count + comments_count)) DESC, created_at DESC)
  WHERE deleted_at IS NULL AND is_story = FALSE;

------------------------------------------------------------------------------
-- 4. The feed.
------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.personal_feed(
  INT, INT, TEXT, TEXT, DOUBLE PRECISION, TIMESTAMPTZ, UUID
);

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
STABLE
-- Deliberately SECURITY INVOKER. Everything below is readable only because
-- row level security says the caller may read it; that is the whole point of
-- this migration. Do not make this SECURITY DEFINER to make it faster.
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  v_uid    UUID := (SELECT auth.uid());
  v_bucket TEXT;
  v_tribe  UUID;
  v_anchor TIMESTAMPTZ := COALESCE(p_anchor, now());
  v_limit  INT := GREATEST(1, LEAST(COALESCE(p_limit, 20), 50));
  v_after  INT := GREATEST(0, COALESCE(p_after_position, 0));
  v_pool   INT;
  v_mode   TEXT := COALESCE(p_mode, 'foryou');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF v_mode NOT IN ('foryou', 'hot', 'fresh') THEN
    RAISE EXCEPTION 'invalid_mode';
  END IF;

  -- The pool has to reach at least as far as the page being asked for. Deep
  -- scrolling past it ends the feed, which is the intended behaviour: nobody
  -- is served a thousandth-best post.
  v_pool := LEAST(1200, GREATEST(400, (v_after + v_limit) * 4));

  SELECT lower(home_city) INTO v_bucket
    FROM public.users WHERE user_id = v_uid;

  IF p_tribe_slug IS NOT NULL THEN
    SELECT t.tribe_id INTO v_tribe
      FROM public.tribes t WHERE t.slug = p_tribe_slug;
    IF v_tribe IS NULL THEN RETURN; END IF;
  END IF;

  RETURN QUERY
  WITH
  my_tribes AS (
    SELECT tm.tribe_id FROM public.tribe_members AS tm WHERE tm.user_id = v_uid
  ),
  my_friends AS (
    -- friendships stores the pair ordered (user_a < user_b), so membership has
    -- to be checked from both ends and the friend is whichever one is not me.
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
  ---------------------------------------------------------------------------
  -- The candidate pool. Four bounded arms instead of one unbounded scan.
  -- Each arm is an index walk with a LIMIT, so row level security is only
  -- evaluated on the rows actually taken rather than on every post ever
  -- written. Everything is anchored at v_anchor, which the client echoes back
  -- with its cursor, so the pool a reader is paging through does not shift
  -- under them when somebody posts.
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
  pool AS (
    SELECT DISTINCT ON (u.post_id) u.*
      FROM (
        SELECT * FROM arm_fresh
        UNION ALL
        SELECT * FROM arm_popular
        UNION ALL
        SELECT * FROM arm_friends
        UNION ALL
        SELECT * FROM arm_tribes
      ) AS u
     ORDER BY u.post_id
  ),
  -- Ranking needs eight columns off the post; the forty a card is drawn from
  -- are fetched at the end, for the twenty rows actually being returned.
  -- Reading them for the whole pool means running the row level security
  -- policy a thousand times to throw nine hundred and eighty of the results
  -- away.
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
  ),
  scored AS (
    SELECT
      v.*,
      -- COALESCE, not bare OR: a post with no tribe tested against a
      -- non-empty tribe list yields NULL, and a NULL here would open a third
      -- partition below and hand out twice the reserved slots.
      COALESCE(
        v.author_id IN (SELECT friend_id FROM my_friends)
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
                  -- Clamped, and this is not decoration: exp() of a numeric
                  -- that far below zero underflows out of double precision
                  -- and raises, which a two-year-old post in the pool will
                  -- do on the first page it appears in.
                  40.0
                )::DOUBLE PRECISION
              )
            - CASE WHEN si.seen_at IS NOT NULL THEN 1.5 ELSE 0 END
          )::DOUBLE PRECISION
        ELSE
          (
            -- Quality. A comment costs more to write than a tap, so it counts
            -- for more, and the logarithm keeps a runaway post from owning
            -- every feed in the country.
            0.6 * ln(1 + v.likes_count + 2 * v.comments_count)
            -- Recency as a decay, not a ramp. Age can only ever cost a post,
            -- and the cost flattens: half of this term is gone in about half a
            -- day, so a post with a hundred hugs from this morning still beats
            -- an empty post from an hour ago.
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
            -- Affinity. Being friends is the most explicit statement someone
            -- makes about whose posts they want, so it is the strongest of
            -- these — worth roughly thirty-five reactions.
            + CASE WHEN v.author_id IN (SELECT friend_id FROM my_friends)
                   THEN 2.2 ELSE 0 END
            + CASE WHEN v.tribe_id IN (SELECT tribe_id FROM my_tribes)
                   THEN 1.2 ELSE 0 END
            + CASE WHEN v.category_name IN (SELECT category_name FROM my_categories)
                   THEN 0.6 ELSE 0 END
            + CASE WHEN v_bucket IS NOT NULL AND v.location_bucket = v_bucket
                   THEN 0.4 ELSE 0 END
            -- A pile-on reads as an argument, not a conversation.
            - CASE WHEN v.comments_count > v.likes_count * 4
                   THEN 0.5 ELSE 0 END
            -- Already seen, and the demotion fades over about three days, so
            -- a post you scrolled past this morning drops out of today's feed
            -- without being banished from next week's.
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
            -- A little noise, deterministically: the same reader gets the same
            -- shuffle all day, so pagination still lines up, and a different
            -- one tomorrow. Enough to break ties, not enough to promote a bad
            -- post over a good one.
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
        -- page. Computed over the whole pool rather than the page so a post's
        -- score does not change as you scroll. Never applied to Fresh, which
        -- has to stay strictly chronological.
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
      s.*,
      (ROW_NUMBER() OVER (ORDER BY s.slot, s.rn))::INTEGER AS fpos
    FROM slotted AS s
  ),
  page AS (
    SELECT pd.post_id, pd.final_score, pd.fpos
      FROM placed AS pd
     WHERE pd.fpos > v_after
     ORDER BY pd.fpos
     LIMIT v_limit
  )
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
    pge.final_score,
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
    pge.fpos,
    v_anchor
  FROM page AS pge
  JOIN public.feed_posts AS f ON f.post_id = pge.post_id
  ORDER BY pge.fpos;
END;
$$;

REVOKE ALL ON FUNCTION public.personal_feed(
  INT, TEXT, TIMESTAMPTZ, INT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.personal_feed(
  INT, TEXT, TIMESTAMPTZ, INT, TEXT, TEXT, TEXT, TEXT
) TO authenticated, service_role;

------------------------------------------------------------------------------
-- 5. feed_hot goes away.
------------------------------------------------------------------------------
-- It has not been readable by a client since its backing cache was revoked
-- from authenticated, and personal_feed(p_mode => 'hot') replaces it with a
-- path that respects row level security. mv_hot_posts and its refresh job stay
-- where they are: the Super Admin console's health probe reads the cache
-- through a role-checked RPC.
DROP VIEW IF EXISTS public.feed_hot;

SELECT public.record_migration(
  '20261058090000', 'a_feed_that_moves'
);

NOTIFY pgrst, 'reload schema';
