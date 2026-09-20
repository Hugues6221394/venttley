BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
VALUES
('1a440000-0000-4000-8000-000000000001','inboxsuper','inboxsuper','x','Inbox Super','inbox super','inboxsuper','super_admin','active',1990),
('1a440000-0000-4000-8000-000000000002','inboxsupport','inboxsupport','x','Inbox Support','inbox support','inboxsupport','support','active',1990),
('1a440000-0000-4000-8000-000000000003','inboxmember','inboxmember','x','Inbox Member','inbox member','inboxmember','normal','active',1990),
('1a440000-0000-4000-8000-000000000004','inboxadmin','inboxadmin','x','Inbox Admin','inbox admin','inboxadmin','admin','active',1990);
SET session_replication_role=origin;

SELECT ok(NOT (SELECT enabled FROM private.staff_inbox_control),'inbox defaults to disabled');
SELECT ok(NOT has_function_privilege('anon','public.admin_staff_attention()','EXECUTE'),'anonymous cannot read attention');
SELECT ok(NOT has_function_privilege('authenticated','private.process_staff_inbox(integer)','EXECUTE'),'clients cannot dispatch or fabricate deliveries');
SELECT ok(NOT has_table_privilege('authenticated','private.staff_inbox_deliveries','SELECT'),'direct inbox access denied');
SELECT is((SELECT count(*)::INTEGER FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='private' AND c.relname IN ('staff_inbox_control','staff_event_outbox','staff_inbox_deliveries','staff_inbox_preferences','staff_attention_snapshots') AND c.relrowsecurity),5,'private tables have RLS');

INSERT INTO private.support_cases(support_case_id,source_kind,category,assigned_to,status,sla_due_at,created_by)
VALUES ('1a440000-1000-4000-8000-000000000001','other','technical','1a440000-0000-4000-8000-000000000002','assigned',now()+interval '1 day','1a440000-0000-4000-8000-000000000001');
SELECT is((SELECT count(*)::INTEGER FROM private.staff_event_outbox WHERE source_id='1a440000-1000-4000-8000-000000000001'),0,'disabled source trigger emits nothing');
UPDATE private.staff_inbox_control SET enabled=true,audience_roles=ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor'];
UPDATE private.support_cases SET assigned_to=NULL WHERE support_case_id='1a440000-1000-4000-8000-000000000001';
UPDATE private.support_cases SET assigned_to='1a440000-0000-4000-8000-000000000002' WHERE support_case_id='1a440000-1000-4000-8000-000000000001';
UPDATE private.support_cases SET assigned_to='1a440000-0000-4000-8000-000000000002' WHERE support_case_id='1a440000-1000-4000-8000-000000000001';
SELECT is((SELECT count(*)::INTEGER FROM private.staff_event_outbox WHERE source_id='1a440000-1000-4000-8000-000000000001'),1,'unchanged assignment does not duplicate an event');
SELECT lives_ok('SELECT private.process_staff_inbox(100)','worker dispatches events');
SELECT lives_ok('SELECT private.process_staff_inbox(100)','worker replay succeeds');
SELECT is((SELECT count(*)::INTEGER FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id) WHERE o.source_id='1a440000-1000-4000-8000-000000000001'),1,'delivery is unique per event and recipient');

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a440000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal2"}',true);
SELECT throws_like('SELECT public.admin_staff_attention()','%not_authorized%','members cannot read counts');
SELECT throws_like('SELECT * FROM public.admin_staff_inbox()','%not_authorized%','members cannot read inbox');
SELECT throws_like('SELECT public.admin_staff_inbox_preferences(false)','%not_authorized%','members cannot change staff preferences');
SELECT set_config('request.jwt.claims','{"sub":"1a440000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
SELECT is((SELECT count(*)::INTEGER FROM public.admin_staff_inbox()),1,'recipient can read own metadata-only notification');
SELECT is((public.admin_staff_attention()->>'unread_count')::INTEGER,1,'bell unread count uses personal unread deliveries');
SELECT is((SELECT destination FROM public.admin_staff_inbox() LIMIT 1),'/support/cases','destination is server-derived');
SELECT is(public.admin_staff_inbox_set_read(ARRAY[(SELECT event_id FROM public.admin_staff_inbox() LIMIT 1)],true),1,'mark read changes recipient state');
SELECT is(public.admin_staff_inbox_set_read(ARRAY[(SELECT event_id FROM public.admin_staff_inbox() LIMIT 1)],true),0,'mark read retry is idempotent');
SELECT is((public.admin_staff_attention()->>'unread_count')::INTEGER,0,'read notification leaves unread count');
SELECT is((SELECT count(*)::INTEGER FROM public.admin_staff_inbox('unread')),0,'unread filter matches count');
SELECT is(public.admin_staff_inbox_set_read(ARRAY[(SELECT event_id FROM public.admin_staff_inbox() LIMIT 1)],false),1,'mark unread works');
SELECT is((SELECT count(*)::INTEGER FROM public.admin_staff_inbox('assigned')),1,'assigned filter validates current assignment');
SELECT is((SELECT count(*)::INTEGER FROM public.admin_staff_inbox('urgent')),0,'ordinary assignment not presented as critical');
SELECT is((SELECT count(*)::INTEGER FROM public.admin_staff_inbox('all',30,
  (SELECT delivered_at FROM public.admin_staff_inbox() LIMIT 1),
  (SELECT event_id FROM public.admin_staff_inbox() LIMIT 1))),0,'cursor excludes previous row');
SELECT throws_like($$SELECT * FROM public.admin_staff_inbox('all',1000)$$,'%invalid_inbox_query%','page size bounded');
SELECT throws_like($$SELECT * FROM public.admin_staff_inbox('all',30,now(),NULL)$$,'%invalid_inbox_query%','half cursor rejected');
SELECT is(public.admin_staff_inbox_preferences(false),false,'optional assignments can be disabled');
SELECT set_config('request.jwt.claims','{"sub":"1a440000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT is((SELECT count(*)::INTEGER FROM public.admin_staff_inbox()),0,'super admin cannot read another recipient inbox');
RESET role;
SELECT is((SELECT status FROM private.support_cases WHERE support_case_id='1a440000-1000-4000-8000-000000000001'),'assigned','read state never resolves the case');

INSERT INTO private.support_cases(support_case_id,source_kind,category,assigned_to,status,sla_due_at,created_by)
VALUES ('1a440000-1000-4000-8000-000000000002','other','technical','1a440000-0000-4000-8000-000000000002','assigned',now()-interval '1 hour','1a440000-0000-4000-8000-000000000001');
SELECT lives_ok('SELECT private.process_staff_inbox(100)','SLA reconciliation dispatches');
SELECT lives_ok('SELECT private.process_staff_inbox(100)','SLA reconciliation is replayable');
SELECT is((SELECT count(*)::INTEGER FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
  WHERE o.source_id='1a440000-1000-4000-8000-000000000002' AND o.kind='support_assigned'),0,'optional event suppressed at delivery');
SELECT is((SELECT status FROM private.staff_event_outbox WHERE source_id='1a440000-1000-4000-8000-000000000002' AND kind='support_assigned'),'skipped','a muted notification is not falsely marked delivered');
SELECT is((SELECT count(*)::INTEGER FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
  WHERE o.source_id='1a440000-1000-4000-8000-000000000002' AND o.kind='support_sla_breached'),1,'critical SLA notice cannot be muted and is not duplicated');

INSERT INTO private.legal_requests(legal_request_id,request_type,jurisdiction,external_reference_hash,scope_code,due_at,created_by,status)
VALUES('1a440000-2000-4000-8000-000000000001','court_order','RW',repeat('a',64),'account_metadata',now()+interval '1 day','1a440000-0000-4000-8000-000000000004','awaiting_approval');
SELECT lives_ok('SELECT private.process_staff_inbox(100)','legal approval dispatches');
SELECT is((SELECT count(*)::INTEGER FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
  WHERE o.source_id='1a440000-2000-4000-8000-000000000001' AND d.recipient_id='1a440000-0000-4000-8000-000000000001'),1,'legal approval routed to independent super admin');
SELECT is((SELECT count(*)::INTEGER FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
  WHERE o.source_id='1a440000-2000-4000-8000-000000000001' AND d.recipient_id='1a440000-0000-4000-8000-000000000002'),0,'support receives no legal approval event');

-- Simulate a delivery failure. The worker must isolate it, retain no message
-- body, back off, and stop after five attempts rather than retrying forever.
CREATE FUNCTION pg_temp.fail_inbox_test_delivery() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS(SELECT 1 FROM private.staff_event_outbox o WHERE o.event_id=NEW.event_id
    AND o.source_id='1a440000-1000-4000-8000-000000000003') THEN
    RAISE EXCEPTION 'sensitive failure detail must never be retained';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER test_delivery_failure BEFORE INSERT ON private.staff_inbox_deliveries
  FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_inbox_test_delivery();
INSERT INTO private.support_cases(support_case_id,source_kind,category,priority,assigned_to,status,sla_due_at,created_by)
VALUES ('1a440000-1000-4000-8000-000000000003','other','technical','critical','1a440000-0000-4000-8000-000000000002','assigned',now()+interval '1 day','1a440000-0000-4000-8000-000000000001');
SELECT lives_ok('SELECT private.process_staff_inbox(100)','delivery failure does not abort worker');
SELECT ok((SELECT next_attempt_at>now() FROM private.staff_event_outbox WHERE source_id='1a440000-1000-4000-8000-000000000003'),'failed attempt backs off');
DO $$ BEGIN
  FOR i IN 1..4 LOOP
    UPDATE private.staff_event_outbox SET next_attempt_at=now() WHERE source_id='1a440000-1000-4000-8000-000000000003';
    PERFORM private.process_staff_inbox(100);
  END LOOP;
END $$;
SELECT is((SELECT status FROM private.staff_event_outbox WHERE source_id='1a440000-1000-4000-8000-000000000003'),'failed','exhausted event enters failed state');
SELECT is((SELECT attempts FROM private.staff_event_outbox WHERE source_id='1a440000-1000-4000-8000-000000000003'),5,'attempt count is bounded');
SELECT is((SELECT last_error_code FROM private.staff_event_outbox WHERE source_id='1a440000-1000-4000-8000-000000000003'),'P0001','only SQLSTATE retained, not sensitive failure detail');
SELECT is((SELECT count(*)::INTEGER FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
  WHERE o.source_id='1a440000-1000-4000-8000-000000000003'),0,'failed delivery leaves no partial recipient record');
DROP TRIGGER test_delivery_failure ON private.staff_inbox_deliveries;

SET session_replication_role=replica;
UPDATE public.users SET user_role='analyst' WHERE user_id='1a440000-0000-4000-8000-000000000002';
SET session_replication_role=origin;
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a440000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);
SELECT is((SELECT count(*)::INTEGER FROM public.admin_staff_inbox()),0,'role change removes access to previously delivered source');
SELECT is((public.admin_staff_attention()->>'unread_count')::INTEGER,0,'badges recheck source access after demotion');
SELECT is(jsonb_array_length(public.admin_staff_attention()->'queues'),0,'role change removes restricted queue aggregates');
RESET role;
SET session_replication_role=replica;
UPDATE public.users SET account_status='suspended' WHERE user_id='1a440000-0000-4000-8000-000000000002';
SET session_replication_role=origin;
SET LOCAL role authenticated;
SELECT throws_like('SELECT public.admin_staff_attention()','%not_authorized%','suspended staff cannot read persisted notifications');
RESET role;
UPDATE private.staff_inbox_control SET enabled=false;
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a440000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT is(public.admin_staff_attention(),' {"enabled":false}'::JSONB,'kill switch disables attention without deleting data');
SELECT is((SELECT count(*)::INTEGER FROM public.admin_staff_inbox()),0,'kill switch hides inbox');
SELECT set_config('request.jwt.claims','{"sub":"1a440000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
SELECT throws_like($$SELECT public.admin_configure_staff_inbox('1a440000-3000-4000-8000-000000000001',true)$$,'%aal2_required%','rollout needs step-up authentication');
SELECT set_config('request.jwt.claims','{"sub":"1a440000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok($$SELECT public.admin_configure_staff_inbox('1a440000-3000-4000-8000-000000000001',true)$$,'super admin can enable a pilot');
SELECT lives_ok($$SELECT public.admin_configure_staff_inbox('1a440000-3000-4000-8000-000000000001',true)$$,'rollout retry is idempotent');
SELECT throws_like($$SELECT public.admin_configure_staff_inbox('1a440000-3000-4000-8000-000000000001',false)$$,'%idempotency_payload_mismatch%','rollout retry cannot change intent');
SELECT is(public.admin_staff_inbox_health()->'audience_roles','["super_admin"]'::JSONB,'initial pilot includes only super admins');
SELECT set_config('request.jwt.claims','{"sub":"1a440000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal2"}',true);
SELECT is(public.admin_staff_attention(),' {"enabled":false}'::JSONB,'nonpilot staff cannot see inbox even when globally enabled');
SELECT throws_like($$SELECT public.admin_configure_staff_inbox('1a440000-3000-4000-8000-000000000002',true)$$,'%not_authorized%','ordinary admin cannot widen rollout');
SELECT throws_like('SELECT public.admin_staff_inbox_health()','%not_authorized%','worker health limited to super admin');
RESET role;
SELECT is((SELECT count(*)::INTEGER FROM public.audit_log WHERE target_id='1a440000-3000-4000-8000-000000000001' AND action='staff_inbox.configure'),1,'rollout has one audit receipt');
SELECT * FROM finish();
ROLLBACK;
