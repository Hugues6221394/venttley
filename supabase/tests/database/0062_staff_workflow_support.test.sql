BEGIN;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO auth.users(id) VALUES('1a620000-0000-4000-8000-000000000001'),('1a620000-0000-4000-8000-000000000002');
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,user_role,account_status,birth_year,display_name,display_name_normalized,username_normalized)
VALUES('1a620000-0000-4000-8000-000000000001','workflowtest','x','x','support','active',1990,'Workflow Test','workflow test','workflowtest'),
('1a620000-0000-4000-8000-000000000002','workflowinactive','x','x','support','suspended',1990,'Workflow Inactive','workflow inactive','workflowinactive');
SET session_replication_role=origin;
INSERT INTO private.support_cases(support_case_id,source_kind,category,priority,status,sla_due_at,created_by,updated_at)
SELECT ('1a620000-1000-4000-8000-00000000000'||i)::uuid,'other','technical','critical','open','1900-01-01'::timestamptz,
'1a620000-0000-4000-8000-000000000001','2000-01-01' FROM generate_series(1,3)i;
SELECT ok(NOT has_function_privilege('anon','public.admin_support_assignees(text)','EXECUTE'),'anonymous staff lookup denied');
SELECT ok(NOT has_function_privilege('anon','public.admin_support_work_queue(text,text,text,timestamptz,uuid,integer)','EXECUTE'),'anonymous queue denied');
SELECT ok(NOT has_function_privilege('anon','public.admin_update_support_case_checked(uuid,uuid,text,text,uuid,timestamptz)','EXECUTE'),'anonymous checked update denied');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a620000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
SELECT is((SELECT count(*)::int FROM public.admin_support_assignees('Workflow')),1,'inactive staff excluded');
SELECT is((SELECT username FROM public.admin_support_assignees('Workflow')),'workflowtest','display name and handle returned');
SELECT is((SELECT count(*)::int FROM public.admin_support_assignees('%')),0,'wildcard is literal');
SELECT throws_like($$SELECT * FROM public.admin_support_assignees(repeat('x',51))$$,'%invalid_query%','oversized search rejected');
SELECT is((SELECT count(*)::int FROM public.admin_support_work_queue('open','all','critical',NULL,NULL,2)),2,'first page bounded');
SELECT is((SELECT support_case_id::text FROM public.admin_support_work_queue('open','all','critical','1900-01-01','1a620000-1000-4000-8000-000000000002',1)),'1a620000-1000-4000-8000-000000000003','cursor tie breaks without repeating rows');
SELECT throws_like($$SELECT * FROM public.admin_support_work_queue('open','all','all',NULL,'1a620000-1000-4000-8000-000000000002',2)$$,'%invalid_queue%','partial cursor rejected');
SELECT throws_like($$SELECT * FROM public.admin_support_work_queue('open','all','all',NULL,NULL,500)$$,'%invalid_queue%','unbounded page rejected');
SELECT throws_like($$SELECT public.admin_update_support_case_checked('1a620000-2000-4000-8000-000000000001','1a620000-1000-4000-8000-000000000001','assigned','high','1a620000-0000-4000-8000-000000000001','2000-01-01')$$,'%aal2_required%','checked update preserves AAL2');
SELECT set_config('request.jwt.claims','{"sub":"1a620000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT throws_ok($$SELECT public.admin_update_support_case_checked('1a620000-2000-4000-8000-000000000001','1a620000-1000-4000-8000-000000000001','assigned','high','1a620000-0000-4000-8000-000000000001','1999-01-01')$$,'PT409','workflow_conflict','stale update is an HTTP conflict, never a retried serialization failure');
SELECT lives_ok($$SELECT public.admin_update_support_case_checked('1a620000-2000-4000-8000-000000000001','1a620000-1000-4000-8000-000000000001','assigned','high','1a620000-0000-4000-8000-000000000001','2000-01-01')$$,'current version accepted');
SELECT lives_ok($$SELECT public.admin_update_support_case_checked('1a620000-2000-4000-8000-000000000001','1a620000-1000-4000-8000-000000000001','assigned','high','1a620000-0000-4000-8000-000000000001','2000-01-01')$$,'same operation replay succeeds after version changed');
SELECT throws_like($$SELECT public.admin_update_support_case_checked('1a620000-2000-4000-8000-000000000001','1a620000-1000-4000-8000-000000000001','closed','high','1a620000-0000-4000-8000-000000000001','2000-01-01')$$,'%idempotency_payload_mismatch%','changed retry rejected');
SELECT is((SELECT count(*)::int FROM public.admin_support_work_queue('open','mine','high',NULL,NULL,50)),1,'mine derives actor from session');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM private.support_case_events WHERE support_case_id='1a620000-1000-4000-8000-000000000001'),1,'duplicate save cannot duplicate events');
SELECT is((SELECT status FROM private.support_cases WHERE support_case_id='1a620000-1000-4000-8000-000000000001'),'assigned','only accepted state persisted');

CREATE FUNCTION pg_temp.check_workflow_role(r TEXT) RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.users SET user_role=r::public.user_role_type WHERE user_id='1a620000-0000-4000-8000-000000000001';
  PERFORM * FROM public.admin_support_assignees('Workflow');
  PERFORM * FROM public.admin_support_work_queue();
  RETURN true;
END;
$$;
SELECT ok(pg_temp.check_workflow_role('super_admin'),'super admin allowed');
SELECT ok(pg_temp.check_workflow_role('admin'),'admin allowed');
SELECT ok(pg_temp.check_workflow_role('support'),'support allowed');
SELECT throws_like($$SELECT pg_temp.check_workflow_role('moderator')$$,'%not_authorized%','moderator denied');
SELECT throws_like($$SELECT pg_temp.check_workflow_role('analyst')$$,'%not_authorized%','analyst denied');
SELECT throws_like($$SELECT pg_temp.check_workflow_role('read_only_auditor')$$,'%not_authorized%','auditor denied');
SELECT throws_like($$SELECT pg_temp.check_workflow_role('normal')$$,'%not_authorized%','member denied');
UPDATE public.users SET account_status='suspended',user_role='support' WHERE user_id='1a620000-0000-4000-8000-000000000001';
SET LOCAL ROLE authenticated;
SELECT throws_like($$SELECT * FROM public.admin_support_work_queue()$$,'%not_authorized%','suspended session denied');
SELECT throws_like($$SELECT * FROM public.admin_support_assignees()$$,'%not_authorized%','suspended selector denied');
SELECT throws_like($$SELECT public.admin_update_support_case_checked('1a620000-2000-4000-8000-000000000001','1a620000-1000-4000-8000-000000000001','assigned','high','1a620000-0000-4000-8000-000000000001','2000-01-01')$$,'%not_authorized%','revoked actor cannot replay old receipt');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
