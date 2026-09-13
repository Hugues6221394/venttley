-- The home tribes rail has been dropping six columns.
--
-- recommended_tribes declares an explicit RETURNS TABLE and its column list
-- stopped at theme_color. Every other path to a Tribe reads tribe_directory —
-- either directly with select(), or through user_public_tribes, which returns
-- SETOF tribe_directory and so widens automatically whenever the view does.
-- This one does not, and nothing failed when the view grew: PostgREST simply
-- omits a column that was never selected, and `row['whatever']` comes back
-- null, which is indistinguishable from a real null.
--
-- So on the home rail, and only there, every tribe rendered with no keeper
-- photo, no lifecycle status, no tags. Exactly the silent degradation
-- row_shape_guard.dart was written for after this happened four times before.
--
-- The guard did fire. It said "these six columns are missing, run
-- home_topic_stats_and_tribe_profiles and tribe_lifecycle_management" — and
-- both are applied, on local and production. So the warning read as a false
-- alarm and was ignored, including by me until I checked the view. It was
-- right that something was wrong and wrong about what: the columns exist, this
-- function just never asked for them. The guard reports once per source and
-- latches on the first row it sees, and the home rail loads first, so this
-- function's answer was the only one it ever heard.
--
-- lifecycle_status is always 'active' here — the WHERE clause below already
-- filters on it — but it is returned anyway so the row's shape matches every
-- other path. A shape that differs by caller is what caused this.
--
-- Dropped and recreated rather than replaced: changing a RETURNS TABLE is a
-- change of return type, which CREATE OR REPLACE refuses.

BEGIN;

DROP FUNCTION IF EXISTS public.recommended_tribes(INT);

CREATE OR REPLACE FUNCTION public.recommended_tribes(p_limit integer DEFAULT 10)
 RETURNS TABLE(tribe_id uuid, name text, slug text, description text, category text, member_count integer, is_private boolean, created_at timestamp with time zone, avatar_url text, banner_url text, is_featured boolean, keeper_id uuid, keeper_pseudonym text, keeper_avatar_seed text, keeper_is_verified boolean, theme_color text, lifecycle_status text, lifecycle_reason text, paused_at timestamp with time zone, deletion_purge_at timestamp with time zone, tags text[], keeper_profile_photo_url text, affinity double precision)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    t.lifecycle_status::TEXT,
    t.lifecycle_reason::TEXT,
    t.paused_at::TIMESTAMPTZ,
    t.deletion_purge_at::TIMESTAMPTZ,
    t.tags::TEXT[],
    t.keeper_profile_photo_url::TEXT,
    (
        COALESCE((SELECT ft.friends_in FROM friend_tribes AS ft
                   WHERE ft.tribe_id = t.tribe_id), 0) * 2.0
      + COALESCE((SELECT mc.weight FROM my_categories AS mc
                   WHERE mc.category_name = t.category), 0) * 0.9
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
      + ln(1 + GREATEST(t.member_count, 0)) * 0.35
      + CASE WHEN t.is_featured THEN 0.4 ELSE 0 END
      - CASE WHEN t.tribe_id IN (SELECT mt.tribe_id FROM my_tribes AS mt)
             THEN 2.5 ELSE 0 END
      - COALESCE((SELECT GREATEST(0, 3.0 - s.hours_ago / 8.0)
                    FROM shown AS s WHERE s.item_id = t.tribe_id), 0)
    )::DOUBLE PRECISION AS affinity
  FROM public.tribe_directory AS t
  WHERE t.is_suspended IS NOT TRUE
    AND t.is_private IS NOT TRUE
    -- New: paused, archived and pending-deletion tribes are not suggestions.
    AND t.lifecycle_status = 'active'
    AND (t.keeper_id IS NULL
         OR t.keeper_id NOT IN (SELECT mb.other FROM my_blocks AS mb))
  ORDER BY affinity DESC, t.member_count DESC, t.tribe_id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
END $function$;

REVOKE ALL ON FUNCTION public.recommended_tribes(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recommended_tribes(INT) TO authenticated;

SELECT public.record_migration(
  '20261024090000', 'recommended_tribes_full_row'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
