BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(53);

SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
VALUES
('1a430000-0000-4000-8000-000000000001','govsuperone','govsuperone','x','Governance Super One','governance super one','govsuperone','super_admin','active',1990),
('1a430000-0000-4000-8000-000000000002','govsupertwo','govsupertwo','x','Governance Super Two','governance super two','govsupertwo','super_admin','active',1990),
('1a430000-0000-4000-8000-000000000003','govadmin','govadmin','x','Governance Admin','governance admin','govadmin','admin','active',1990),
('1a430000-0000-4000-8000-000000000004','govsupport','govsupport','x','Governance Support','governance support','govsupport','support','active',1990),
('1a430000-0000-4000-8000-000000000005','govmember','govmember','x','Governance Member','governance member','govmember','normal','active',1990);
SET session_replication_role=origin;

SELECT has_table('private','support_cases','canonical support cases are private');
SELECT has_table('private','legal_requests','canonical legal requests are private');
SELECT has_table('private','crisis_playbooks','versioned crisis playbooks are private');
SELECT has_table('private','recovery_drills','recovery evidence is private');
SELECT is((SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='private' AND c.relname IN ('admin_operation_receipts','support_cases','support_case_events','legal_requests','legal_request_events','crisis_playbooks','crisis_playbook_acknowledgements','recovery_drills') AND c.relrowsecurity),8,
  'all operational tables enable row-level security as defense in depth');
SELECT ok(NOT has_table_privilege('authenticated','private.support_cases','SELECT')
  AND NOT has_table_privilege('authenticated','private.legal_requests','SELECT')
  AND NOT has_table_privilege('authenticated','private.crisis_playbooks','SELECT')
  AND NOT has_table_privilege('authenticated','private.recovery_drills','SELECT'),
  'authenticated clients have no direct table access');
SELECT ok(NOT has_function_privilege('anon','public.admin_create_support_case(uuid,text,uuid,uuid,text,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.admin_create_legal_request(uuid,text,text,text,text,timestamptz)','EXECUTE')
  AND NOT has_function_privilege('anon','public.admin_publish_crisis_playbook(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.admin_verify_recovery_drill(uuid,uuid)','EXECUTE'),
  'anonymous callers cannot execute governance RPCs');
SELECT ok(to_regclass('public.support_cases') IS NULL AND to_regclass('public.legal_requests') IS NULL
  AND to_regclass('public.crisis_playbooks') IS NULL AND to_regclass('public.recovery_drills') IS NULL,
  'no operational records are mirrored into the exposed public schema');

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2"}',true);
SELECT throws_like($q$SELECT * FROM public.admin_support_case_queue(10)$q$,'%not_authorized%',
  'ordinary members cannot read the support queue');
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}',true);
SELECT throws_like($q$SELECT public.admin_create_support_case('1a430000-1000-4000-8000-000000000001','other',NULL,'1a430000-0000-4000-8000-000000000005','technical','normal')$q$,'%aal2_required%',
  'a support password without MFA cannot open a case');
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($q$SELECT public.admin_create_support_case('1a430000-1000-4000-8000-000000000001','other',NULL,'1a430000-0000-4000-8000-000000000005','technical','normal')$q$,
  'stepped-up support can open a metadata-only case');
SELECT is(
  public.admin_create_support_case('1a430000-1000-4000-8000-000000000001','other',NULL,'1a430000-0000-4000-8000-000000000005','technical','normal')::text,
  public.admin_create_support_case('1a430000-1000-4000-8000-000000000001','other',NULL,'1a430000-0000-4000-8000-000000000005','technical','normal')::text,
  'replaying the same operation is idempotent');
SELECT throws_like($q$SELECT public.admin_create_support_case('1a430000-1000-4000-8000-000000000001','other',NULL,'1a430000-0000-4000-8000-000000000005','technical','high')$q$,'%idempotency_payload_mismatch%',
  'reusing an operation ID with a changed payload fails closed');
SELECT throws_like($q$SELECT public.admin_create_support_case('1a430000-1000-4000-8000-000000000099','privacy','1a430000-9000-4000-8000-000000000001',NULL,'privacy_request','normal')$q$,'%unsupported_source_binding%',
  'a client cannot bind an arbitrary UUID as an unsupported source record');
SELECT is((SELECT count(*)::int FROM public.admin_support_case_queue(10)),1,
  'the retry did not create duplicate cases');
SELECT is((public.admin_control_plane_snapshot('support_cases')#>>'{data,dedicated_support_case_entity_available}')::boolean,true,
  'the compatibility snapshot now reports the canonical support entity truthfully');
SELECT lives_ok($q$SELECT public.admin_update_support_case('1a430000-1000-4000-8000-000000000002',
  (SELECT support_case_id FROM public.admin_support_case_queue(10) LIMIT 1),'assigned','high','1a430000-0000-4000-8000-000000000004')$q$,
  'support can assign and prioritize a case through the actor-bound RPC');
SELECT is((SELECT first_response_at::text FROM public.admin_support_case_queue(10) LIMIT 1),NULL::text,
  'assignment does not fabricate a member-response timestamp');
SELECT throws_like($q$SELECT * FROM private.support_cases$q$,'%permission denied%',
  'even support staff cannot bypass the queue DTO');
RESET role;

INSERT INTO public.rate_limits(user_id,action_key,window_started_at,counter)
VALUES('1a430000-0000-4000-8000-000000000004','admin_support_create',now(),60)
ON CONFLICT(user_id,action_key) DO UPDATE SET window_started_at=now(),counter=60;
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal2"}',true);
SELECT throws_like($q$SELECT public.admin_create_support_case('1a430000-1000-4000-8000-000000000098','other',NULL,NULL,'technical','normal')$q$,'%rate_limited%',
  'the database quota blocks direct RPC mutation even when the Next.js limiter is bypassed');
RESET role;

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($q$SELECT public.admin_create_legal_request('1a430000-2000-4000-8000-000000000001','court_order','RW',repeat('a',64),'account_metadata',now()+interval '7 days')$q$,
  'a stepped-up super admin can register a hashed legal reference');
RESET role;

INSERT INTO private.legal_requests(legal_request_id,request_type,jurisdiction,external_reference_hash,scope_code,due_at,created_by)
VALUES('1a430000-2000-4000-8000-000000000010','court_order','RW',repeat('b',64),'account_disclosure',now()+interval '7 days','1a430000-0000-4000-8000-000000000001');
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT throws_like($q$SELECT public.admin_decide_legal_request('1a430000-2000-4000-8000-000000000002','1a430000-2000-4000-8000-000000000010',true,true,'valid_authority',repeat('c',64))$q$,'%independent_approver_required%',
  'the legal-request creator cannot approve their own disclosure');
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($q$SELECT public.admin_decide_legal_request('1a430000-2000-4000-8000-000000000003','1a430000-2000-4000-8000-000000000010',true,true,'valid_authority',repeat('c',64))$q$,
  'a different super admin can approve after authority and manifest checks');
RESET role;
SELECT is((SELECT status FROM private.legal_requests WHERE legal_request_id='1a430000-2000-4000-8000-000000000010'),'approved',
  'approval persisted');
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($q$SELECT public.admin_mark_legal_request_fulfilled('1a430000-2000-4000-8000-000000000004','1a430000-2000-4000-8000-000000000010',repeat('d',64))$q$,
  'a completion receipt can be recorded only after approval');
RESET role;
SELECT is((SELECT status FROM private.legal_requests WHERE legal_request_id='1a430000-2000-4000-8000-000000000010'),'fulfilled',
  'legal fulfilment persisted with its receipt');
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($q$SELECT * FROM public.admin_legal_request_queue(10)$q$,
  'an active admin can read the minimized legal register');
SELECT is((public.admin_control_plane_snapshot('legal_requests')#>>'{data,legal_request_entity_available}')::boolean,true,
  'the compatibility snapshot reports the legal-request entity as available');
SELECT lives_ok($q$SELECT public.admin_create_crisis_playbook('1a430000-3000-4000-8000-000000000001','GLOBAL',10,'Global operational test',repeat('Safe response procedure. ',4))$q$,
  'an admin can create a versioned playbook draft');
RESET role;

INSERT INTO private.crisis_playbooks(playbook_id,region_code,version,title,body_markdown,body_hash,created_by)
VALUES('1a430000-3000-4000-8000-000000000010','RW',1,'Rwanda crisis response',repeat('Contain, communicate, recover. ',3),
  encode(extensions.digest(repeat('Contain, communicate, recover. ',3),'sha256'),'hex'),'1a430000-0000-4000-8000-000000000001');
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT throws_like($q$SELECT public.admin_publish_crisis_playbook('1a430000-3000-4000-8000-000000000002','1a430000-3000-4000-8000-000000000010')$q$,'%independent_publisher_required%',
  'a playbook author cannot publish their own version');
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($q$SELECT public.admin_publish_crisis_playbook('1a430000-3000-4000-8000-000000000003','1a430000-3000-4000-8000-000000000010')$q$,
  'a different super admin can publish the exact version');
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($q$SELECT * FROM public.admin_crisis_playbooks(10)$q$,
  'support staff can read the crisis procedure they must follow');
SELECT is((public.admin_control_plane_snapshot('crisis_playbooks')#>>'{data,playbook_acknowledgement_available}')::boolean,true,
  'the compatibility snapshot reports playbook acknowledgement as available');
SELECT lives_ok($q$SELECT public.admin_ack_crisis_playbook('1a430000-3000-4000-8000-000000000004','1a430000-3000-4000-8000-000000000010')$q$,
  'support can acknowledge the exact published hash');
SELECT lives_ok($q$SELECT public.admin_ack_crisis_playbook('1a430000-3000-4000-8000-000000000005','1a430000-3000-4000-8000-000000000010')$q$,
  'acknowledging again is retry-safe even with a new logical operation');
RESET role;
SELECT is((SELECT count(*)::int FROM private.crisis_playbook_acknowledgements WHERE playbook_id='1a430000-3000-4000-8000-000000000010'),1,
  'one immutable acknowledgement was recorded');
SELECT throws_like($q$UPDATE private.crisis_playbooks SET body_markdown='silently changed' WHERE playbook_id='1a430000-3000-4000-8000-000000000010'$q$,'%published_playbook_immutable%',
  'published playbook content cannot be silently edited');

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($q$SELECT public.admin_create_recovery_drill('1a430000-4000-4000-8000-000000000001','isolated_restore',now()+interval '1 day',60,120)$q$,
  'an admin can schedule an explicit recovery drill');
RESET role;
INSERT INTO private.recovery_drills(recovery_drill_id,environment,scheduled_at,expected_rpo_minutes,expected_rto_minutes,created_by)
VALUES('1a430000-4000-4000-8000-000000000010','isolated_restore',now(),60,120,'1a430000-0000-4000-8000-000000000003');
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($q$SELECT public.admin_complete_recovery_drill('1a430000-4000-4000-8000-000000000002','1a430000-4000-4000-8000-000000000010',true,15,45,12,12,repeat('e',64))$q$,
  'a stepped-up operator can record bounded results and evidence');
SELECT throws_like($q$SELECT public.admin_verify_recovery_drill('1a430000-4000-4000-8000-000000000003','1a430000-4000-4000-8000-000000000010')$q$,'%independent_verifier_required%',
  'the result recorder cannot verify their own drill');
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($q$SELECT public.admin_verify_recovery_drill('1a430000-4000-4000-8000-000000000004','1a430000-4000-4000-8000-000000000010')$q$,
  'a different super admin can verify the drill evidence');
RESET role;
SELECT is((SELECT status FROM private.recovery_drills WHERE recovery_drill_id='1a430000-4000-4000-8000-000000000010'),'verified',
  'independent recovery verification persisted');
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a430000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($q$SELECT * FROM public.admin_recovery_drills(10)$q$,
  'an admin can read the minimized recovery register');
SELECT is((public.admin_control_plane_snapshot('recovery_readiness')#>>'{data,recovery_drill_register_available}')::boolean,true,
  'the compatibility snapshot reports the recovery drill register as available');
RESET role;

SELECT throws_like($q$UPDATE private.admin_operation_receipts SET request_hash=repeat('f',64)$q$,'%immutable_operational_record%',
  'retry receipts are append-only');
SELECT throws_like($q$DELETE FROM private.legal_request_events$q$,'%immutable_operational_record%',
  'legal decision history is append-only');
SELECT ok((SELECT count(*) >= 10 FROM public.audit_log WHERE actor_id::text LIKE '1a430000-%'),
  'operational mutations produced actor-bound audit records');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN (
    'admin_create_support_case','admin_update_support_case','admin_support_case_queue',
    'admin_create_legal_request','admin_decide_legal_request','admin_mark_legal_request_fulfilled','admin_legal_request_queue',
    'admin_create_crisis_playbook','admin_publish_crisis_playbook','admin_ack_crisis_playbook','admin_crisis_playbooks',
    'admin_create_recovery_drill','admin_complete_recovery_drill','admin_verify_recovery_drill','admin_recovery_drills'
  ) AND p.prosecdef AND EXISTS(SELECT 1 FROM unnest(COALESCE(p.proconfig,ARRAY[]::text[])) s WHERE s='search_path=""')),15,
  'all public workflow RPCs are security definer functions with an empty search path');
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN (
    'admin_create_support_case','admin_update_support_case','admin_create_legal_request','admin_decide_legal_request',
    'admin_mark_legal_request_fulfilled','admin_create_crisis_playbook','admin_publish_crisis_playbook',
    'admin_ack_crisis_playbook','admin_create_recovery_drill','admin_complete_recovery_drill','admin_verify_recovery_drill'
  ) AND p.prosrc !~ 'claim_rate_limit'),0,
  'every operational mutation has a database-enforced caller quota');
SELECT throws_like($q$INSERT INTO private.crisis_playbooks(region_code,version,title,body_markdown,body_hash,status,created_by,published_by,published_at)
  VALUES('RW',2,'Conflicting published version',repeat('Safe procedure. ',5),repeat('f',64),'published','1a430000-0000-4000-8000-000000000001','1a430000-0000-4000-8000-000000000002',now())$q$,
  '%duplicate key%','only one crisis playbook may be published per region');
SELECT ok((SELECT count(*) >= 9 FROM private.admin_operation_receipts),
  'successful logical operations have durable retry receipts');
SELECT ok((SELECT approved_by<>created_by AND disclosure_manifest_hash IS NOT NULL AND completion_receipt_hash IS NOT NULL
  FROM private.legal_requests WHERE legal_request_id='1a430000-2000-4000-8000-000000000010'),
  'legal disclosure evidence binds independent approval, manifest, and completion receipt');
SELECT ok((SELECT completed_by<>verified_by AND evidence_hash IS NOT NULL
  FROM private.recovery_drills WHERE recovery_drill_id='1a430000-4000-4000-8000-000000000010'),
  'recovery evidence binds completion to an independent verifier');

SELECT * FROM finish();
ROLLBACK;
