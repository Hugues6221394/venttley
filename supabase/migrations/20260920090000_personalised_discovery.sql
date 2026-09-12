-- The discovery modules were the same for everybody, and never changed.
--
-- Two accounts side by side showed byte-identical home screens: the same
-- whisper rail in the same order, the same "Popular right now" avatars, the
-- same trending tribes. Pulling to refresh changed nothing. The post list was
-- genuinely personal — personal_feed ranks on friends, tribes, liked
-- categories and location — but it is one strip of that screen, and everything
-- around it was global:
--
--   * Trending Tribes:  tribe_directory ORDER BY member_count DESC
--                       One fixed ordering. The biggest tribes are the biggest
--                       tribes for everyone, for ever.
--   * Whispers rail:    list_unheard_whispers, which filters what you have
--                       finished listening to but then orders the remainder
--                       the same way every time.
--
-- Neither had any notion of who was asking, and neither had any notion of what
-- it had already shown you. Those are two different problems and both have to
-- be solved, because personalisation alone still produces a frozen screen: a
-- perfectly targeted recommendation you have already ignored six times is
-- worse than an average one you have not seen.
--
-- SO: RANK PER PERSON, THEN ROTATE
--
-- discovery_impressions records what each home module actually put in front of
-- somebody. A recently-shown item is penalised rather than removed — removing
-- it would mean a small app runs out of things to show and the module empties,
-- while a penalty lets a strong recommendation come back later, further down.
-- That is the behaviour people read as "the feed refreshed".
--
-- Write volume is deliberately bounded: only the home discovery modules write
-- here, roughly ten rows per pull-to-refresh, and rows older than three days
-- are pruned. This is not a per-post impression log — that would be a genuine
-- scale decision, and is not what these two modules need.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. What we have already shown you
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.discovery_impressions (
  user_id  UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  kind     TEXT NOT NULL CHECK (kind IN ('tribe', 'whisper')),
  item_id  UUID NOT NULL,
  seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, kind, item_id)
);

COMMENT ON TABLE public.discovery_impressions IS
  'What the home discovery modules have shown each person, so a refresh brings different things. Bounded on purpose: home modules only, pruned after three days.';

CREATE INDEX IF NOT EXISTS discovery_impressions_recent_idx
  ON public.discovery_impressions (user_id, kind, seen_at DESC);

ALTER TABLE public.discovery_impressions ENABLE ROW LEVEL SECURITY;

-- Readable and writable only through the SECURITY DEFINER functions below, so
-- nobody can inspect or forge somebody else's impression history.
REVOKE ALL ON TABLE public.discovery_impressions
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.note_discovery_impressions(
  p_kind TEXT,
  p_ids  UUID[]
)
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_n  INT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF p_kind NOT IN ('tribe', 'whisper') THEN
    RAISE EXCEPTION 'invalid_kind';
  END IF;
  IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN RETURN 0; END IF;

  INSERT INTO public.discovery_impressions (user_id, kind, item_id, seen_at)
  SELECT v_me, p_kind, id, now()
    -- Capped so a malicious or looping client cannot write unbounded rows.
    FROM unnest(p_ids[1:100]) AS id
  ON CONFLICT (user_id, kind, item_id) DO UPDATE SET seen_at = now();

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION public.note_discovery_impressions(TEXT, UUID[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.note_discovery_impressions(TEXT, UUID[])
  TO authenticated;

CREATE OR REPLACE FUNCTION public.prune_discovery_impressions()
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_n INT;
BEGIN
  DELETE FROM public.discovery_impressions
   WHERE seen_at < now() - INTERVAL '3 days';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION public.prune_discovery_impressions()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prune_discovery_impressions() TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Tribes worth joining, for you specifically
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.recommended_tribes(p_limit INT DEFAULT 10)
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
  keeper_avatar_seed VARCHAR,
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
  SELECT
    t.tribe_id, t.name, t.slug, t.description, t.category, t.member_count,
    t.is_private, t.created_at, t.avatar_url, t.banner_url, t.is_featured,
    t.keeper_id, t.keeper_pseudonym, t.keeper_avatar_seed,
    t.keeper_is_verified, t.theme_color,
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
      -- The rotation term. Something shown minutes ago is pushed well down;
      -- the penalty decays to nothing over about a day, so a good tribe
      -- returns rather than being blacklisted.
      - COALESCE((SELECT GREATEST(0, 3.0 - s.hours_ago / 8.0)
                    FROM shown AS s WHERE s.item_id = t.tribe_id), 0)
    )::DOUBLE PRECISION AS affinity
  FROM public.tribe_directory AS t
  WHERE t.is_suspended IS NOT TRUE
    AND t.is_private IS NOT TRUE
    AND t.tribe_id NOT IN (SELECT mt.tribe_id FROM my_tribes AS mt)
    AND (t.keeper_id IS NULL
         OR t.keeper_id NOT IN (SELECT mb.other FROM my_blocks AS mb))
  ORDER BY affinity DESC, t.member_count DESC, t.tribe_id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
END $$;

COMMENT ON FUNCTION public.recommended_tribes(INT) IS
  'Per-user tribe suggestions: friends'' tribes, categories you engage with, recent activity, size logarithmically — minus a decaying penalty for what you were shown recently, so refreshing changes the list.';

REVOKE ALL ON FUNCTION public.recommended_tribes(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recommended_tribes(INT) TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20260920090000', 'personalised_discovery'
);

NOTIFY pgrst, 'reload schema';
