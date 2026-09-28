BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
VALUES
('1a680000-0000-4000-8000-000000000001','recoverysuper','recoverysuper','x','Recovery Super','recovery super','recoverysuper','super_admin','active',1990),
('1a680000-0000-4000-8000-000000000002','recoveryother','recoveryother','x','Recovery Other','recovery other','recoveryother','admin','active',1990);
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
SELECT ('1a680000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'recoveryrole'||n,'recoveryrole'||n,'x','Recovery Role','recovery role','recoveryrole'||n,r::public.user_role_type,'active',1990
FROM (VALUES(3,'moderator'),(4,'support'),(5,'analyst'),(6,'read_only_auditor')) AS roles(n,r);
SET session_replication_role=origin;
INSERT INTO private.support_cases(support_case_id,source_kind,category,assigned_to,status,sla_due_at,created_by)
VALUES ('1a680000-1000-4000-8000-000000000001','other','technical','1a680000-0000-4000-8000-000000000001','assigned',now()+interval '1 day','1a680000-0000-4000-8000-000000000001');
-- Two failures at an identical time pin UUID tie-breaking; a missing source
-- must never be revealed or retried, even to a super admin.
INSERT INTO private.staff_event_outbox(event_id,event_key,kind,source_id,intended_recipient,severity,status,attempts,last_error_code,created_at)
SELECT ('1a680000-2000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'recovery-test-'||n,'support_assigned',
 CASE WHEN n=3 THEN '1a680000-1000-4000-8000-000000000099'::uuid ELSE '1a680000-1000-4000-8000-000000000001'::uuid END,
 '1a680000-0000-4000-8000-000000000001','critical','failed',5,'P0001','1700-01-01'::timestamptz
FROM generate_series(1,3)n;
INSERT INTO private.staff_inbox_deliveries(event_id,recipient_id,read_at)
VALUES('1a680000-2000-4000-8000-000000000001','1a680000-0000-4000-8000-000000000001','2020-01-01');
SELECT ok(NOT has_function_privilege('anon','public.admin_staff_inbox_failures(timestamptz,uuid,integer)','EXECUTE'),'anonymous cannot inspect failures');
SELECT ok(NOT has_function_privilege('anon','public.admin_retry_staff_notification(uuid,uuid,text)','EXECUTE'),'anonymous cannot retry');
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a680000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
SELECT is((SELECT count(*)::int FROM public.admin_staff_inbox_failures() WHERE event_id::text LIKE '1a680000%'),2,'failed list excludes missing sources');
SELECT is((SELECT event_id FROM public.admin_staff_inbox_failures(NULL,NULL,1)),'1a680000-2000-4000-8000-000000000001'::uuid,'oldest failure first');
SELECT is((SELECT event_id FROM public.admin_staff_inbox_failures('1700-01-01','1a680000-2000-4000-8000-000000000001',1)),'1a680000-2000-4000-8000-000000000002'::uuid,'paired cursor crosses timestamp ties');
SELECT throws_like($$SELECT public.admin_staff_inbox_failures(now(),NULL,31)$$,'%invalid_cursor%','half cursor rejected');
SELECT throws_like($$SELECT public.admin_staff_inbox_failures(NULL,NULL,52)$$,'%invalid_cursor%','page size capped');
SELECT throws_like($$SELECT public.admin_retry_staff_notification('1a680000-3000-4000-8000-000000000001','1a680000-2000-4000-8000-000000000001','reviewed_retry')$$,'%aal2_required%','MFA required');
SELECT set_config('request.jwt.claims','{"sub":"1a680000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT throws_like($$SELECT public.admin_retry_staff_notification('1a680000-3000-4000-8000-000000000001','1a680000-2000-4000-8000-000000000001','reviewed_retry')$$,'%staff_inbox_disabled%','recovery cannot bypass rollout kill switch');
RESET role;
UPDATE private.staff_inbox_control SET enabled=true,audience_roles=ARRAY['super_admin'];
SET LOCAL role authenticated;
SELECT throws_like($$SELECT public.admin_retry_staff_notification('1a680000-3000-4000-8000-000000000001','1a680000-2000-4000-8000-000000000001','private free text')$$,'%invalid_reason%','only safe reason codes accepted');
SELECT throws_like($$SELECT public.admin_retry_staff_notification('1a680000-3000-4000-8000-000000000001','1a680000-2000-4000-8000-000000000003','reviewed_retry')$$,'%not_authorized%','missing source cannot be retried');
SELECT lives_ok($$SELECT public.admin_retry_staff_notification('1a680000-3000-4000-8000-000000000001','1a680000-2000-4000-8000-000000000001','reviewed_retry')$$,'failed event can be requeued');
SELECT lives_ok($$SELECT public.admin_retry_staff_notification('1a680000-3000-4000-8000-000000000001','1a680000-2000-4000-8000-000000000001','reviewed_retry')$$,'same operation is retry safe');
SELECT throws_like($$SELECT public.admin_retry_staff_notification('1a680000-3000-4000-8000-000000000001','1a680000-2000-4000-8000-000000000001','configuration_fixed')$$,'%idempotency_payload_mismatch%','receipt cannot change intent');
SELECT throws_ok($$SELECT public.admin_retry_staff_notification('1a680000-3000-4000-8000-000000000002','1a680000-2000-4000-8000-000000000001','reviewed_retry')$$,'PT409','workflow_conflict','new operation cannot retry a pending event');
RESET role;
SELECT is((SELECT attempts FROM private.staff_event_outbox WHERE event_id='1a680000-2000-4000-8000-000000000001'),0,'retry budget resets only on authorized recovery');
SELECT is((SELECT status FROM private.staff_event_outbox WHERE event_id='1a680000-2000-4000-8000-000000000001'),'pending','event identity preserved and requeued');
SELECT lives_ok('SELECT private.process_staff_inbox(100)','normal worker delivers recovery');
SELECT is((SELECT count(*)::int FROM private.staff_inbox_deliveries WHERE event_id='1a680000-2000-4000-8000-000000000001'),1,'recovery does not duplicate delivery');
SELECT is((SELECT read_at FROM private.staff_inbox_deliveries WHERE event_id='1a680000-2000-4000-8000-000000000001'),'2020-01-01'::timestamptz,'recovery does not make read notices unread');
SELECT is((SELECT status FROM private.staff_event_outbox WHERE event_id='1a680000-2000-4000-8000-000000000001'),'delivered','worker persists delivery success');
-- Test every lesser staff role against both entry points with fresh JWTs.
SET LOCAL role authenticated;
DO $$ DECLARE n int; BEGIN
 FOR n IN 2..6 LOOP
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub','1a680000-0000-4000-8000-'||lpad(n::text,12,'0'),'role','authenticated','aal','aal2')::text,true);
  BEGIN PERFORM public.admin_staff_inbox_failures(); RAISE EXCEPTION 'role admitted: %',n;
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.admin_retry_staff_notification('1a680000-3000-4000-8000-000000000003','1a680000-2000-4000-8000-000000000002','reviewed_retry'); RAISE EXCEPTION 'role admitted: %',n;
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 END LOOP;
END $$;
SELECT pass('all five lesser staff roles denied by both recovery interfaces');
RESET role;
SET session_replication_role=replica;
UPDATE public.users SET account_status='suspended' WHERE user_id='1a680000-0000-4000-8000-000000000001';
SET session_replication_role=origin;
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a680000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT throws_like($$SELECT public.admin_staff_inbox_failures()$$,'%not_authorized%','revocation hides failure metadata');
SELECT throws_like($$SELECT public.admin_retry_staff_notification('1a680000-3000-4000-8000-000000000001','1a680000-2000-4000-8000-000000000001','reviewed_retry')$$,'%not_authorized%','revocation rejects even an accepted receipt');
RESET role;
SELECT * FROM finish();
ROLLBACK;
