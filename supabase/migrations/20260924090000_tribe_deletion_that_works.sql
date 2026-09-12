-- "Schedule a deletion" marked the tribe and then nothing ever happened.
--
-- 20260716175655 built a complete lifecycle: set_tribe_lifecycle moves a tribe
-- to 'pending_deletion' with deletion_purge_at = now() + 30 days, and
-- purge_due_tribes soft-deletes its posts and hard-deletes the row once that
-- date passes. Every piece is correct.
--
-- Nothing calls purge_due_tribes. Grepping the whole migrations tree for it
-- returns only its own definition. There is no cron job, no webhook, no
-- trigger. So a keeper who scheduled a deletion got a tribe that was flagged
-- for ever, and still listed in search exactly as before. Which is what
-- happened: "I remember we once scheduled a delete for a tribe but I still can
-- see it when I search."
--
-- Three faults, and each alone was enough to break the feature:
--
--   1. The purge was never scheduled, so the 30 days never elapsed into
--      anything.
--   2. No discovery query filtered on lifecycle_status, so a tribe on its way
--      out stayed in search and in the suggestion rail.
--   3. There was no way to delete immediately. Thirty days is right as a
--      default — it is an undo window for an irreversible act — but it must
--      not be the only option. A tribe created by mistake, or one being used
--      to harass somebody, has to be removable now.
--
-- A CORRECTION TO MY OWN FIRST ATTEMPT
--
-- The first version of this migration also rebuilt tribe_directory to add
-- lifecycle_status, on the belief that the view did not expose it. That was
-- wrong, and Postgres said so: 42P16, "cannot drop columns from view". I had
-- read the definition in 0071 and not noticed that 20260716175655 later
-- replaced it — the live view already carries lifecycle_status, visibility,
-- tags, paused_at, archived_at, deletion_requested_at, deletion_purge_at,
-- lifecycle_reason, settings and both profile photo columns.
--
-- So the view is left exactly as it is. The column was never the problem; the
-- queries simply never used it. Had that CREATE OR REPLACE succeeded it would
-- have silently dropped nine columns that other screens read.

-- ---------------------------------------------------------------------------
-- 2. Delete now, for when thirty days is the wrong answer
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.delete_tribe_now(
  p_tribe_id     UUID,
  p_confirm_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me    UUID := (SELECT auth.uid());
  v_tribe public.tribes;
  v_posts INT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT * INTO v_tribe FROM public.tribes
   WHERE tribe_id = p_tribe_id
     -- Locked for the duration: two taps on "Delete now" must not both get
     -- past the checks and try to delete the same row.
     FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'tribe_not_found'; END IF;

  -- Only the keeper. Not a moderator, not a co-mod with granted permissions —
  -- destroying the whole space is not a delegable act.
  IF v_tribe.keeper_id <> v_me THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  -- Same confirmation set_tribe_lifecycle demands for scheduling. Immediate
  -- deletion has no undo window at all, so the bar cannot be lower.
  IF lower(btrim(COALESCE(p_confirm_name, ''))) <> lower(btrim(v_tribe.name)) THEN
    RAISE EXCEPTION 'tribe_name_confirmation_failed';
  END IF;

  -- Posts are soft-deleted rather than removed, exactly as purge_due_tribes
  -- does. People wrote those words; a keeper deleting their space should not
  -- erase somebody else's vent from the record, and moderation history has to
  -- survive for any report already filed against one.
  UPDATE public.posts AS p
     SET deleted_at = COALESCE(p.deleted_at, now())
   WHERE p.tribe_id = p_tribe_id;
  GET DIAGNOSTICS v_posts = ROW_COUNT;

  -- Named arguments: log_tribe_action's second parameter is the action, and it
  -- takes the actor from auth.uid() itself — passing v_me positionally would
  -- put a UUID where a TEXT action belongs.
  --
  -- The tribe id goes in the metadata because tribe_audit_log.tribe_id is
  -- ON DELETE SET NULL: the row below survives the deletion, but its link to
  -- the tribe does not, so the identifying details have to live in the payload
  -- or the audit entry becomes "somebody deleted something".
  PERFORM public.log_tribe_action(
    p_tribe_id   => p_tribe_id,
    p_action     => 'tribe_deleted_immediately',
    p_target_type => 'tribe',
    p_target_id  => p_tribe_id::TEXT,
    p_reason     => 'keeper requested immediate deletion',
    p_metadata   => jsonb_build_object(
                      'tribe_id', p_tribe_id,
                      'name', v_tribe.name,
                      'slug', v_tribe.slug,
                      'member_count', v_tribe.member_count,
                      'posts_affected', v_posts
                    )
  );

  DELETE FROM public.tribes WHERE tribe_id = p_tribe_id;

  RETURN jsonb_build_object('deleted', TRUE, 'posts_affected', v_posts);
END $$;

COMMENT ON FUNCTION public.delete_tribe_now(UUID, TEXT) IS
  'Keeper-only immediate deletion, gated on typing the tribe name. Posts are soft-deleted like purge_due_tribes does; the tribe row goes. Use set_tribe_lifecycle for the 30-day path.';

REVOKE ALL ON FUNCTION public.delete_tribe_now(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_tribe_now(UUID, TEXT) TO authenticated;

COMMIT;

-- ---------------------------------------------------------------------------
-- 3. Actually run the purge
-- ---------------------------------------------------------------------------
--
-- Hourly. The timer is thirty days, so nothing needs minute precision, and an
-- hourly job costs one indexed lookup against a partial index that already
-- exists (tribes_pending_deletion, from 20260716175655).

DO $$
DECLARE v_jobid INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE EXCEPTION 'pg_cron is not installed; scheduled tribe deletions would never complete.';
  END IF;

  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'purge_due_tribes';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;

  PERFORM cron.schedule(
    'purge_due_tribes', '17 * * * *',
    $cron$ SELECT public.purge_due_tribes(); $cron$
  );
END $$;

SELECT jobname, schedule, active FROM cron.job
 WHERE jobname = 'purge_due_tribes';


-- ---------------------------------------------------------------------------
-- 4. Keep dying tribes out of discovery
-- ---------------------------------------------------------------------------
--
-- Only 'active' tribes belong in a suggestion rail. A paused, archived or
-- pending-deletion tribe is not somewhere to send a new member.
--
-- Deliberately NOT filtered in the view itself: tribe_directory is also how a
-- keeper loads their own tribe in the Studio, and hiding a pending-deletion
-- tribe there would remove the only screen from which they can cancel it. The
-- filter belongs in the discovery queries, not in the source of truth.

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
  keeper_avatar_seed TEXT,
  keeper_is_verified BOOLEAN,
  theme_color TEXT,
  affinity DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
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
END $fn$;

REVOKE ALL ON FUNCTION public.recommended_tribes(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recommended_tribes(INT) TO authenticated;

SELECT public.record_migration(
  '20260924090000', 'tribe_deletion_that_works'
);

NOTIFY pgrst, 'reload schema';
