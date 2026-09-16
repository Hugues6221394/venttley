BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(13);

SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
VALUES
('1a410000-0000-4000-8000-000000000001','controlnormal','controlnormal','x','Control Normal','control normal','controlnormal','normal','active',1990),
('1a410000-0000-4000-8000-000000000002','controlsupport','controlsupport','x','Control Support','control support','controlsupport','support','active',1990),
('1a410000-0000-4000-8000-000000000003','controlanalyst','controlanalyst','x','Control Analyst','control analyst','controlanalyst','analyst','active',1990),
('1a410000-0000-4000-8000-000000000004','controladmin','controladmin','x','Control Admin','control admin','controladmin','admin','active',1990),
('1a410000-0000-4000-8000-000000000005','controlsuper','controlsuper','x','Control Super','control super','controlsuper','super_admin','active',1990);
SET session_replication_role=origin;

SELECT ok(NOT has_function_privilege('anon','public.admin_control_plane_snapshot(text)','EXECUTE'),
  'anonymous callers cannot invoke the operations snapshot');

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a410000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
SELECT throws_like($q$SELECT public.admin_control_plane_snapshot('support_cases')$q$,'%not_authorized%',
  'ordinary members cannot read any control-plane section');
SELECT throws_like($q$SELECT public.admin_control_plane_snapshot('made_up')$q$,'%unknown_control_section%',
  'unknown section names fail before reaching a query branch');

SELECT set_config('request.jwt.claims','{"sub":"1a410000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
SELECT lives_ok($q$SELECT public.admin_control_plane_snapshot('support_cases')$q$,
  'support can read its own aggregate workload');
SELECT lives_ok($q$SELECT public.admin_control_plane_snapshot('crisis_playbooks')$q$,
  'support can read aggregate crisis readiness');
SELECT throws_like($q$SELECT public.admin_control_plane_snapshot('campaigns')$q$,'%not_authorized%',
  'support cannot read coordinated-harm investigation signals');

SELECT set_config('request.jwt.claims','{"sub":"1a410000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}',true);
SELECT lives_ok($q$SELECT public.admin_control_plane_snapshot('model_operations')$q$,
  'analysts can read aggregate model operations');
SELECT lives_ok($q$SELECT public.admin_control_plane_snapshot('transparency_reports')$q$,
  'analysts can read aggregate transparency inputs');
SELECT throws_like($q$SELECT public.admin_control_plane_snapshot('storage_operations')$q$,'%not_authorized%',
  'analysts cannot inspect storage operations');

SELECT set_config('request.jwt.claims','{"sub":"1a410000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}',true);
SELECT throws_like($q$SELECT public.admin_control_plane_snapshot('moderation_workforce')$q$,'%not_authorized%',
  'ordinary admins cannot inspect workforce staffing');

SELECT set_config('request.jwt.claims','{"sub":"1a410000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2"}',true);
SELECT is(
  (SELECT count(*)::integer FROM unnest(ARRAY[
    'campaigns','support_cases','legal_requests','crisis_playbooks','recovery_readiness','moderation_workforce',
    'model_operations','messaging_operations','storage_operations','regional_compliance','transparency_reports','experiments'
  ]) section WHERE public.admin_control_plane_snapshot(section)->>'section'=section),
  12,'super admin can read all twelve valid aggregate sections');
SELECT is(public.admin_control_plane_snapshot('storage_operations')->>'privacy','aggregate_only',
  'every snapshot labels its privacy contract');
RESET role;

SELECT ok(
  (SELECT p.prosecdef AND p.provolatile='s' AND EXISTS(
    SELECT 1 FROM unnest(COALESCE(p.proconfig,ARRAY[]::text[])) setting WHERE setting LIKE 'search_path=%'
  ) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='admin_control_plane_snapshot'),
  'the aggregate function is stable, security definer, and pins an empty search path');

SELECT * FROM finish();
ROLLBACK;
