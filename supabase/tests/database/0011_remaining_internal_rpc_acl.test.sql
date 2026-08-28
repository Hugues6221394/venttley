BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(45);

CREATE TEMP TABLE protected_internal_rpc(signature TEXT PRIMARY KEY);

INSERT INTO protected_internal_rpc(signature) VALUES
  ('public.admin_log(text,text,uuid,text,jsonb,jsonb,text,jsonb)'),
  ('public.assert_author_allowed(uuid)'),
  ('public.award(uuid,text)'),
  ('public.bump_streak(uuid,text,timestamp with time zone)'),
  ('public.consume_moderation_quota(uuid)'),
  ('public.evaluate_user_verification(uuid)'),
  ('public.expire_disappearing_dms()'),
  ('public.expire_due_suspensions()'),
  ('public.log_tribe_action(uuid,text,text,text,text,jsonb,jsonb,jsonb)'),
  ('public.recent_count(text,text,uuid,integer)'),
  ('public.refresh_hot_posts()'),
  ('public.refresh_user_active_days(date)'),
  ('public.require_tribe_owner(uuid)'),
  ('public.run_tribe_daily_checkins()'),
  ('public.sweep_user_verification()');

SELECT ok(
  NOT has_function_privilege('anon', signature, 'EXECUTE'),
  signature || ' is inaccessible to anonymous API callers'
)
FROM protected_internal_rpc
ORDER BY signature;

SELECT ok(
  NOT has_function_privilege('authenticated', signature, 'EXECUTE'),
  signature || ' is inaccessible to signed-in API callers'
)
FROM protected_internal_rpc
ORDER BY signature;

SELECT ok(
  has_function_privilege('service_role', signature, 'EXECUTE'),
  signature || ' remains available to trusted workers'
)
FROM protected_internal_rpc
ORDER BY signature;

SELECT * FROM finish();
ROLLBACK;
