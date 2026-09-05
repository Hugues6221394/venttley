-- The whispers rail went empty, and it was a privilege mistake in 20260920.
--
-- discovery_impressions was created with RLS on and every privilege revoked:
--
--     REVOKE ALL ON TABLE public.discovery_impressions
--       FROM PUBLIC, anon, authenticated;
--
-- The reasoning was that nothing should touch it except the SECURITY DEFINER
-- functions, which run as the table owner and so are unaffected. That held for
-- recommended_tribes, which is SECURITY DEFINER. It does not hold for
-- whispers_for_me, which is SECURITY INVOKER — deliberately, to match
-- list_unheard_whispers and keep the RLS on whispers_feed evaluated as the
-- caller rather than as the owner.
--
-- So whispers_for_me runs as `authenticated`, reaches its `shown` CTE, and gets
-- "permission denied for table discovery_impressions". Observable behaviour:
--
--   * signed out  -> v_me IS NULL, the early-return branch never reads the
--                    table, plain recency comes back fine
--   * signed in   -> the whole call fails, the provider lands in an error
--                    state, .valueOrNull is null, and the rail renders as
--                    nothing at all
--
-- Which is exactly what happened: a rail that had four avatars and three cards
-- came back blank, with no error on screen and nothing in the client log,
-- because the failure was swallowed by valueOrNull.
--
-- THE FIX, AND WHY IT IS NOT A WEAKENING
--
-- Reading your own impression history is not a privilege that needs
-- withholding — it is a list of things the app has already shown you. So
-- authenticated gets SELECT, bounded by an RLS policy to its own rows.
--
-- Writes stay closed. There is no INSERT, UPDATE or DELETE grant, so the only
-- way a row is ever written is still note_discovery_impressions, which is
-- SECURITY DEFINER and stamps user_id from auth.uid(). Nobody can forge or
-- erase somebody else's impression history, and nobody can read it.
--
-- The alternative — making whispers_for_me SECURITY DEFINER — would have been
-- the wrong fix. It would run the whispers_feed query as the owner and quietly
-- bypass the row-level security on the underlying whispers, turning a missing
-- grant into a visibility hole.

BEGIN;

GRANT SELECT ON TABLE public.discovery_impressions TO authenticated;

DROP POLICY IF EXISTS "own impressions readable"
  ON public.discovery_impressions;

CREATE POLICY "own impressions readable"
  ON public.discovery_impressions
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

COMMENT ON POLICY "own impressions readable" ON public.discovery_impressions IS
  'SECURITY INVOKER ranking functions read this as the caller, so the caller needs SELECT on its own rows. Writes remain closed: only note_discovery_impressions inserts, and it stamps user_id from auth.uid().';


-- ---------------------------------------------------------------------------
-- And the same class of mistake in recommended_tribes
-- ---------------------------------------------------------------------------
--
-- Trending Tribes went blank on the same screen, for a different reason:
-- 20260920 excluded tribes you had already joined. Correct for a pure
-- "discover something new" list, wrong for this rail — a Keeper who is a
-- member of nearly every tribe got an empty section and no header at all.
-- Joined tribes are now ranked down rather than removed, so the rail always
-- has something in it.

-- Widening keeper_avatar_seed from VARCHAR to TEXT changes the return type,
-- and CREATE OR REPLACE refuses that with 42P13. So drop and recreate — and
-- the re-GRANT at the bottom is not optional, because dropping a function
-- takes its privileges with it and every signed-in user would lose the rail.
DROP FUNCTION IF EXISTS public.recommended_tribes(INT);

CREATE FUNCTION public.recommended_tribes(p_limit INT DEFAULT 10)
RETURNS TABLE(
  tribe_id UUID,
  name TEXT,
  slug TEXT,
  description TEXT,
  category TEXT,
  member_count INT,
  is_private BOOLEAN,
  created_at TIMESTAMPTZ,
  avatar_url TEXT,
  banner_url TEXT,
  is_featured BOOLEAN,
  keeper_id UUID,
  keeper_pseudonym TEXT,
  keeper_avatar_seed TEXT,
  keeper_is_verified BOOLEAN,
  theme_color TEXT,
  affinity DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
-- Every name in RETURNS TABLE is also a plpgsql variable in scope, so a bare
-- `tribe_id` inside the query is ambiguous and raises at runtime rather than
-- at create time. Resolve towards the column, and qualify anyway — the same
-- directive personal_feed uses for the same reason.
#variable_conflict use_column
DECLARE
  v_me     UUID := (SELECT auth.uid());
  v_bucket TEXT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT lower(home_city) INTO v_bucket
    FROM public.users WHERE user_id = v_me;

  RETURN QUERY
  WITH
  my_tribes AS (
    SELECT tm.tribe_id FROM public.tribe_members AS tm WHERE tm.user_id = v_me
  ),
  my_friends AS (
    SELECT CASE WHEN f.user_a = v_me THEN f.user_b ELSE f.user_a END AS friend_id
      FROM public.friendships AS f
     WHERE f.status = 'accepted' AND (f.user_a = v_me OR f.user_b = v_me)
  ),
  -- Tribes my friends are in. The single most useful signal for "where do I
  -- belong" — far better than which tribe happens to be largest.
  friend_tribes AS (
    SELECT tm.tribe_id, count(*) AS friends_in
      FROM public.tribe_members AS tm
      JOIN my_friends AS mf ON mf.friend_id = tm.user_id
     GROUP BY tm.tribe_id
  ),
  my_categories AS (
    SELECT p.category_name, count(*) AS weight
      FROM public.post_likes AS l
      JOIN public.posts AS p ON p.post_id = l.post_id
     WHERE l.user_id = v_me AND l.created_at > now() - INTERVAL '30 days'
     GROUP BY p.category_name
  ),
  my_blocks AS (
    SELECT ub.blocked_id AS other FROM public.user_blocks AS ub
     WHERE ub.blocker_id = v_me
    UNION
    SELECT ub.blocker_id FROM public.user_blocks AS ub
     WHERE ub.blocked_id = v_me
  ),
  -- Recent activity. A tribe with 900 silent members is a worse suggestion
  -- than one with 40 people actually talking this week.
  activity AS (
    SELECT p.tribe_id, count(*) AS recent_posts
      FROM public.posts AS p
     WHERE p.created_at > now() - INTERVAL '7 days'
       AND p.deleted_at IS NULL
       AND p.tribe_id IS NOT NULL
     GROUP BY p.tribe_id
  ),
  shown AS (
    SELECT di.item_id,
           EXTRACT(EPOCH FROM (now() - di.seen_at)) / 3600.0 AS hours_ago
      FROM public.discovery_impressions AS di
     WHERE di.user_id = v_me AND di.kind = 'tribe'
  )
  -- Every column cast to exactly what RETURNS TABLE declares.
  --
  -- This is why Trending Tribes was erroring rather than merely empty.
  -- tribes.name is spaces.space_name renamed, so it is VARCHAR(100), and
  -- returning it into a column declared TEXT raises "Returned type character
  -- varying does not match expected type text in column 2" on every single
  -- call. It applied cleanly and failed at runtime, which is the worst place
  -- for a type error to live.
  --
  -- Casting explicitly rather than correcting each declared type on purpose:
  -- it is immune to the underlying column changing width or type later, and
  -- it cannot drift the way a hand-copied type list does.
  SELECT
    t.tribe_id::UUID,
    t.name::TEXT,
    t.slug::TEXT,
    t.description::TEXT,
    t.category::TEXT,
    t.member_count::INT,
    t.is_private::BOOLEAN,
    t.created_at::TIMESTAMPTZ,
    t.avatar_url::TEXT,
    t.banner_url::TEXT,
    t.is_featured::BOOLEAN,
    t.keeper_id::UUID,
    t.keeper_pseudonym::TEXT,
    t.keeper_avatar_seed::TEXT,
    t.keeper_is_verified::BOOLEAN,
    t.theme_color::TEXT,
    (
        COALESCE((SELECT ft.friends_in FROM friend_tribes AS ft
                   WHERE ft.tribe_id = t.tribe_id), 0) * 2.0
      + COALESCE((SELECT mc.weight FROM my_categories AS mc
                   WHERE mc.category_name = t.category), 0) * 0.9
      -- Local relevance is measured through the tribe's posts rather than the
      -- tribe row, because tribes have no location of their own. A tribe whose
      -- conversation is happening in your city is a better suggestion than one
      -- that merely shares a category name with it.
      + CASE WHEN v_bucket IS NOT NULL
                  AND EXISTS (
                    SELECT 1 FROM public.posts AS lp
                     WHERE lp.tribe_id = t.tribe_id
                       AND lp.location_bucket = v_bucket
                       AND lp.created_at > now() - INTERVAL '30 days'
                       AND lp.deleted_at IS NULL
                  )
             THEN 0.6 ELSE 0 END
      + ln(1 + COALESCE((SELECT a.recent_posts FROM activity AS a
                          WHERE a.tribe_id = t.tribe_id), 0)) * 1.2
      -- Size still matters, but logarithmically, so it informs the ranking
      -- instead of dictating it the way ORDER BY member_count did.
      + ln(1 + GREATEST(t.member_count, 0)) * 0.35
      + CASE WHEN t.is_featured THEN 0.4 ELSE 0 END
      -- Tribes you are already in sink, but stay.
      --
      -- They used to be filtered out entirely, on the reasoning that a
      -- suggestion should be something new. That emptied the rail for anyone
      -- who had joined most of what exists — the section header vanished and
      -- it read as "my trending tribes are gone". The old rail showed joined
      -- tribes with a tick, so they belong here; they just should not outrank
      -- something you have not found yet.
      - CASE WHEN t.tribe_id IN (SELECT mt.tribe_id FROM my_tribes AS mt)
             THEN 2.5 ELSE 0 END
      -- The rotation term. Something shown minutes ago is pushed well down;
      -- the penalty decays to nothing over about a day, so a good tribe
      -- returns rather than being blacklisted.
      - COALESCE((SELECT GREATEST(0, 3.0 - s.hours_ago / 8.0)
                    FROM shown AS s WHERE s.item_id = t.tribe_id), 0)
    )::DOUBLE PRECISION AS affinity
  FROM public.tribe_directory AS t
  WHERE t.is_suspended IS NOT TRUE
    AND t.is_private IS NOT TRUE
    AND (t.keeper_id IS NULL
         OR t.keeper_id NOT IN (SELECT mb.other FROM my_blocks AS mb))
  ORDER BY affinity DESC, t.member_count DESC, t.tribe_id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
END $$;


COMMENT ON FUNCTION public.recommended_tribes(INT) IS
  'Per-user tribe suggestions: friends'' tribes, categories you engage with, recent activity, size logarithmically. Tribes you already belong to are ranked down rather than excluded, so the rail is never empty. Minus a decaying penalty for what you were shown recently.';

REVOKE ALL ON FUNCTION public.recommended_tribes(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recommended_tribes(INT) TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20260923090000', 'fix_whispers_rail_permission'
);

NOTIFY pgrst, 'reload schema';
