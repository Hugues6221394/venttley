BEGIN;

-- These routines are implementation details for triggers, cron jobs, trusted
-- workers, or higher-level SECURITY DEFINER RPCs. Several accept arbitrary
-- user/resource identifiers and therefore must never be exposed directly
-- through PostgREST to hostile clients.
--
-- Calls made by the owning SECURITY DEFINER routines and pg_cron continue to
-- work. service_role keeps explicit access for operational workers.
REVOKE ALL ON FUNCTION public.admin_log(
  TEXT, TEXT, UUID, TEXT, JSONB, JSONB, TEXT, JSONB
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.assert_author_allowed(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.award(UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bump_streak(UUID, TEXT, TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.consume_moderation_quota(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.evaluate_user_verification(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.expire_disappearing_dms()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.expire_due_suspensions()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.log_tribe_action(
  UUID, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, JSONB
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.recent_count(TEXT, TEXT, UUID, INTEGER)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refresh_hot_posts()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refresh_user_active_days(DATE)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.require_tribe_owner(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.run_tribe_daily_checkins()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sweep_user_verification()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.admin_log(
  TEXT, TEXT, UUID, TEXT, JSONB, JSONB, TEXT, JSONB
) TO service_role;
GRANT EXECUTE ON FUNCTION public.assert_author_allowed(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.award(UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.bump_streak(UUID, TEXT, TIMESTAMPTZ)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.consume_moderation_quota(UUID)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.evaluate_user_verification(UUID)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.expire_disappearing_dms() TO service_role;
GRANT EXECUTE ON FUNCTION public.expire_due_suspensions() TO service_role;
GRANT EXECUTE ON FUNCTION public.log_tribe_action(
  UUID, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, JSONB
) TO service_role;
GRANT EXECUTE ON FUNCTION public.recent_count(TEXT, TEXT, UUID, INTEGER)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.refresh_hot_posts() TO service_role;
GRANT EXECUTE ON FUNCTION public.refresh_user_active_days(DATE)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.require_tribe_owner(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.run_tribe_daily_checkins() TO service_role;
GRANT EXECUTE ON FUNCTION public.sweep_user_verification() TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
