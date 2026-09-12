-- Trending Topics was a global aggregate with no idea who was asking.
--
-- trending_topic_stats is LANGUAGE sql and never calls auth.uid(): it counts
-- posts, comments and reactions per category across the whole app for 30 days
-- and orders by the result. That is a real and useful signal — "what is Venttly
-- talking about" is a genuine fact — but presented alone it means a person who
-- only ever posts in #LateNight opens the app to #Confessions at the top
-- because #Confessions is biggest overall, every single time.
--
-- The fix is a blend, not a replacement. What is globally hot still matters —
-- that is what makes a trending rail feel like a place with other people in it
-- rather than a mirror. But it is weighted against what this person actually
-- engages with, so the ordering differs between accounts and reflects both.
--
-- HOW THE BLEND AVOIDS A SCALE TRAP
--
-- trend_score and personal affinity are measured in unrelated units — one
-- counts app-wide activity, the other counts a single person's likes. Adding
-- them directly would let whichever happens to be numerically larger win by
-- accident, and that balance would silently shift as the app grows. So both
-- are normalised to 0..1 against the maximum in this result set first, and the
-- weights (0.55 global / 0.45 personal) then mean what they say at any scale.
--
-- The returned trend_score is deliberately left as the TRUE global figure.
-- Only the ordering changes. The rail displays counts and that score, and
-- returning a normalised 0..1 blend in a field the UI treats as an activity
-- measure would make the numbers on screen wrong.
--
-- WHY THERE IS NO IMPRESSION-BASED ROTATION HERE
--
-- Unlike tribes and whispers, this is a list of categories — a handful of
-- fixed buckets, not a pool of thousands of items. Penalising a category for
-- having been shown would make the rail claim #LateNight is trending when it
-- is not, which is worse than a stable answer. Instead near-equal topics
-- alternate on an hourly seed, so the rail moves without ever lying about what
-- is actually busy.

BEGIN;

CREATE OR REPLACE FUNCTION public.trending_topics_for_me(p_limit INT DEFAULT 8)
RETURNS TABLE (
  category_name TEXT,
  post_count INT,
  comment_count INT,
  reaction_count INT,
  trend_score DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF p_limit IS NULL OR p_limit < 1 THEN p_limit := 8; END IF;
  IF p_limit > 30 THEN p_limit := 30; END IF;

  -- Signed out: no affinity to blend, so the global trend is the whole answer.
  IF v_me IS NULL THEN
    RETURN QUERY
    SELECT s.category_name, s.post_count, s.comment_count,
           s.reaction_count, s.trend_score
      FROM public.trending_topic_stats(p_limit) AS s;
    RETURN;
  END IF;

  RETURN QUERY
  WITH
  -- Ask for a wider slice than we return, so personal affinity can lift a
  -- category that global ranking would have cut off before we ever saw it.
  base AS (
    SELECT * FROM public.trending_topic_stats(30)
  ),
  my_friends AS (
    SELECT CASE WHEN f.user_a = v_me THEN f.user_b ELSE f.user_a END AS friend_id
      FROM public.friendships AS f
     WHERE f.status = 'accepted' AND (f.user_a = v_me OR f.user_b = v_me)
  ),
  -- Writing in a category is a stronger statement than liking in it, so it is
  -- weighted higher and given a longer window.
  my_posts AS (
    SELECT p.category_name, count(*)::DOUBLE PRECISION * 1.5 AS w
      FROM public.posts AS p
     WHERE p.author_id = v_me
       AND p.deleted_at IS NULL
       AND p.created_at > now() - INTERVAL '90 days'
     GROUP BY p.category_name
  ),
  my_likes AS (
    SELECT p.category_name, count(*)::DOUBLE PRECISION * 1.0 AS w
      FROM public.post_likes AS l
      JOIN public.posts AS p ON p.post_id = l.post_id
     WHERE l.user_id = v_me
       AND l.created_at > now() - INTERVAL '30 days'
     GROUP BY p.category_name
  ),
  -- What the people you chose to be friends with are talking about this week.
  friend_activity AS (
    SELECT p.category_name, count(*)::DOUBLE PRECISION * 0.5 AS w
      FROM public.posts AS p
      JOIN my_friends AS mf ON mf.friend_id = p.author_id
     WHERE p.deleted_at IS NULL
       AND p.created_at > now() - INTERVAL '7 days'
     GROUP BY p.category_name
  ),
  affinity AS (
    SELECT a.category_name, sum(a.w) AS score
      FROM (
        SELECT category_name, w FROM my_posts
        UNION ALL SELECT category_name, w FROM my_likes
        UNION ALL SELECT category_name, w FROM friend_activity
      ) AS a
     WHERE a.category_name IS NOT NULL
     GROUP BY a.category_name
  ),
  -- Normalise both sides against the maximum present, so the weights below
  -- keep meaning the same thing however large the app gets.
  bounds AS (
    SELECT GREATEST((SELECT max(b.trend_score) FROM base AS b), 1.0) AS max_trend,
           GREATEST((SELECT max(af.score) FROM affinity AS af), 1.0) AS max_aff
  )
  SELECT b.category_name, b.post_count, b.comment_count, b.reaction_count,
         -- The true global figure, unchanged. Only the ordering is personal.
         b.trend_score
    FROM base AS b
    CROSS JOIN bounds AS bd
    LEFT JOIN affinity AS af ON af.category_name = b.category_name
   ORDER BY
     (
       -- Log-normalised, not a raw ratio.
       --
       -- Measured: with Confessions at trend 600 and LateNight at 93, a raw
       -- ratio put Confessions at 1.0 and LateNight at 0.155, so a person who
       -- writes exclusively in LateNight and has never touched Confessions
       -- still saw Confessions first — global won 0.550 to 0.535. One
       -- dominant category simply crushed the personal side.
       --
       -- Logs fix that the same way they do for member_count and plays_count
       -- elsewhere: being six times bigger still ranks higher, but not six
       -- times higher, so affinity can actually move the order.
         0.55 * (ln(1 + GREATEST(b.trend_score, 0)) / ln(1 + bd.max_trend))
       + 0.45 * (ln(1 + GREATEST(COALESCE(af.score, 0), 0)) / ln(1 + bd.max_aff))
       -- Hourly tiebreak. Deterministic within the hour — two calls a minute
       -- apart agree, so the rail does not flicker while somebody is looking
       -- at it — but near-equal topics trade places through the day. The
       -- magnitude is small enough that it can never reorder topics that
       -- genuinely differ.
       + 0.02 * (
           ('x' || substr(md5(b.category_name ||
              to_char(now(), 'YYYYMMDDHH24')), 1, 4))::BIT(16)::INT / 65535.0
         )
     ) DESC,
     b.trend_score DESC,
     b.category_name
   LIMIT p_limit;
END $$;

COMMENT ON FUNCTION public.trending_topics_for_me(INT) IS
  'Trending categories blended 55/45 between the global trend and this person''s own engagement, both normalised. trend_score stays the true global figure; only the ordering is personal.';

REVOKE ALL ON FUNCTION public.trending_topics_for_me(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trending_topics_for_me(INT)
  TO anon, authenticated;

COMMIT;

SELECT public.record_migration('20260922090000', 'trending_topics_for_me');

NOTIFY pgrst, 'reload schema';
