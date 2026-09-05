-- The whispers rail was recency, and recency is the same for everybody.
--
-- list_unheard_whispers does one genuinely useful thing — it skips whispers you
-- have finished listening to — and then orders whatever is left by
-- created_at DESC. So two accounts that have listened to nothing see the same
-- whispers in the same order, the "Popular right now" avatars are the same four
-- faces, and pulling to refresh re-fetches the identical list. That is what was
-- on screen in the two side-by-side screenshots.
--
-- This adds a ranked sibling rather than changing list_unheard_whispers. That
-- function is the Whispers *screen's* feed, where reverse-chronological with
-- keyset pagination is the correct behaviour and its cursor contract must not
-- move. What the home rail needs is different: a handful of whispers worth
-- opening, chosen for this person, different next time.
--
-- RETURNS SETOF public.whispers_feed deliberately. The score is computed in a
-- subquery and used only for ordering, never returned. That keeps the row shape
-- byte-identical to the existing feed, so the Dart mapper and its column guard
-- need no changes — and there is no new column for a future reader to forget
-- to select, which is the failure that put unscanned images on the home feed.
--
-- WHAT IT KEEPS FROM THE ORIGINAL
--
-- The empty-feed fallback, and for the reason the original states: somebody who
-- has heard everything must not open the app to nothing, because on a support
-- platform that reads as abandonment rather than as being caught up. Same rule
-- here — if personal ranking yields nothing, fall back to recency rather than
-- returning an empty rail.

BEGIN;

CREATE OR REPLACE FUNCTION public.whispers_for_me(
  p_limit    INT  DEFAULT 24,
  p_category TEXT DEFAULT NULL
)
RETURNS SETOF public.whispers_feed
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF p_limit IS NULL OR p_limit < 1 THEN p_limit := 24; END IF;
  IF p_limit > 50 THEN p_limit := 50; END IF;

  -- Signed out: there is nobody to personalise for, and no impression history
  -- to rotate against. Recency is the honest answer.
  IF v_me IS NULL THEN
    RETURN QUERY
    SELECT f.*
      FROM public.whispers_feed AS f
     WHERE f.deleted_at IS NULL
       AND f.media_status <> 'blocked'
       AND (p_category IS NULL OR f.category_name = p_category)
     ORDER BY f.created_at DESC, f.whisper_id DESC
     LIMIT p_limit;
    RETURN;
  END IF;

  RETURN QUERY
  WITH
  my_friends AS (
    SELECT CASE WHEN fr.user_a = v_me THEN fr.user_b ELSE fr.user_a END AS friend_id
      FROM public.friendships AS fr
     WHERE fr.status = 'accepted'
       AND (fr.user_a = v_me OR fr.user_b = v_me)
  ),
  my_categories AS (
    SELECT p.category_name, count(*) AS weight
      FROM public.post_likes AS l
      JOIN public.posts AS p ON p.post_id = l.post_id
     WHERE l.user_id = v_me
       AND l.created_at > now() - INTERVAL '30 days'
     GROUP BY p.category_name
  ),
  my_blocks AS (
    SELECT ub.blocked_id AS other FROM public.user_blocks AS ub
     WHERE ub.blocker_id = v_me
    UNION
    SELECT ub.blocker_id FROM public.user_blocks AS ub
     WHERE ub.blocked_id = v_me
  ),
  shown AS (
    SELECT di.item_id,
           EXTRACT(EPOCH FROM (now() - di.seen_at)) / 3600.0 AS hours_ago
      FROM public.discovery_impressions AS di
     WHERE di.user_id = v_me AND di.kind = 'whisper'
  ),
  -- Only the id and the score. Joining this back to the view means the final
  -- SELECT is a plain f.*, which is exactly the row type this function
  -- promises — no column list to write out, and none to get wrong later.
  scored AS (
    SELECT
      f.whisper_id,
      (
        -- A friend's voice is the whole reason to open this rail.
          CASE WHEN f.author_id IN (SELECT mf.friend_id FROM my_friends AS mf)
               THEN 2.5 ELSE 0 END
        + COALESCE((SELECT mc.weight FROM my_categories AS mc
                     WHERE mc.category_name = f.category_name), 0) * 0.9
        -- Popularity, logarithmically: a whisper with 400 plays is better than
        -- one with 40, but not ten times better, and a brand new whisper with
        -- none should still be reachable.
        + ln(1 + GREATEST(COALESCE(f.plays_count, 0), 0)) * 0.5
        + ln(1 + GREATEST(COALESCE(f.likes_count, 0), 0)) * 0.4
        -- Freshness, on the same 45000-second scale personal_feed uses so the
        -- two rankings age content at the same rate.
        + EXTRACT(EPOCH FROM (f.created_at - TIMESTAMPTZ '2024-01-01')) / 45000.0
        -- Rotation, and it has to outweigh the popularity terms above.
        --
        -- Measured: at 3.0 the single most-played whisper stayed pinned to the
        -- top across refreshes, because ln(401)*0.5 + ln(91)*0.4 is about 3.5.
        -- A rail whose first slot never changes is the exact complaint this
        -- migration exists to fix, so the penalty is set above the realistic
        -- ceiling of those terms. It still decays to nothing over roughly a
        -- day, so a genuinely popular whisper returns rather than being
        -- suppressed permanently.
        - COALESCE((SELECT GREATEST(0, 5.0 - s.hours_ago / 5.0)
                      FROM shown AS s WHERE s.item_id = f.whisper_id), 0)
      ) AS rank_score
    FROM public.whispers_feed AS f
   WHERE f.deleted_at IS NULL
     -- The scanner's verdict is not advisory. Blocked audio artwork never
     -- reaches a rail, whatever it scores.
     AND f.media_status <> 'blocked'
     AND (p_category IS NULL OR f.category_name = p_category)
     -- Your own whisper is not a discovery suggestion. It was appearing in the
     -- rail, which is how "tester keeper" ended up recommended to itself.
     AND f.author_id <> v_me
     AND f.author_id NOT IN (SELECT mb.other FROM my_blocks AS mb)
     AND NOT EXISTS (
       SELECT 1 FROM public.whisper_listens AS wl
        WHERE wl.whisper_id = f.whisper_id
          AND wl.listener_id = v_me
     )
  )
  SELECT f.*
    FROM public.whispers_feed AS f
    JOIN scored AS s ON s.whisper_id = f.whisper_id
   ORDER BY s.rank_score DESC, f.created_at DESC, f.whisper_id DESC
   LIMIT p_limit;

  -- Heard everything, or blocked everyone, or the only whispers are your own.
  -- An empty rail on a support platform reads as abandonment, so fall back.
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT f.*
      FROM public.whispers_feed AS f
     WHERE f.deleted_at IS NULL
       AND f.media_status <> 'blocked'
       AND (p_category IS NULL OR f.category_name = p_category)
     ORDER BY f.created_at DESC, f.whisper_id DESC
     LIMIT p_limit;
  END IF;
END $$;

COMMENT ON FUNCTION public.whispers_for_me(INT, TEXT) IS
  'Per-user whisper ranking for the home rail: friends, categories you engage with, popularity and freshness, minus a decaying penalty for what you were shown recently. Row shape is identical to whispers_feed on purpose.';

REVOKE ALL ON FUNCTION public.whispers_for_me(INT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.whispers_for_me(INT, TEXT)
  TO anon, authenticated;

COMMIT;

SELECT public.record_migration('20260921090000', 'whispers_for_me');

NOTIFY pgrst, 'reload schema';
