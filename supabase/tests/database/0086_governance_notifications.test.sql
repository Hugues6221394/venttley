-- PREPARED, NOT RUN. Disposable database only, after all draft dependencies.
-- Notification tests seed workflow records; workflow mutation adversarial tests
-- remain in the separate access review / promotion / broadcast test files.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
SELECT ('1c792000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'govnotice'||n,'govnotice'||n,'x','Operator','operator','govnotice'||n,r::public.user_role_type,'active',1990
FROM (VALUES(1,'super_admin'),(2,'super_admin'),(3,'admin'),(4,'moderator'),(5,'support'),(6,'analyst'),(7,'read_only_auditor'),(8,'normal'))t(n,r);
INSERT INTO auth.users(id,aud,role,created_at,updated_at)
SELECT user_id,'authenticated','authenticated',now(),now() FROM public.users WHERE anonymous_pseudonym LIKE 'govnotice%';
INSERT INTO auth.sessions(id,user_id,created_at,updated_at,aal)
SELECT user_id,user_id,now(),now(),'aal2' FROM public.users WHERE anonymous_pseudonym LIKE 'govnotice%';
SET session_replication_role=origin;
CREATE FUNCTION pg_temp.id(n INT) RETURNS UUID LANGUAGE sql AS $$SELECT ('1c792000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID$$;
CREATE FUNCTION pg_temp.claim(n INT,aal TEXT DEFAULT 'aal2') RETURNS VOID LANGUAGE sql AS $$
 SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.id(n),'session_id',pg_temp.id(n),'role','authenticated','aal',aal)::TEXT,true)::TEXT;
$$;
CREATE FUNCTION pg_temp.notices() RETURNS BIGINT LANGUAGE sql AS $$SELECT count(*) FROM public.admin_staff_inbox_page('all','governance')$$;
UPDATE private.staff_inbox_control SET enabled=true,audience_roles=ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor'];
UPDATE private.access_review_control SET enabled=true;
UPDATE private.promotion_control SET enabled=true;
UPDATE private.broadcast_approval_control SET enabled=true;
INSERT INTO private.access_review_campaigns(campaign_id,period,due_at,created_by) VALUES(pg_temp.id(100),'2026-10-01',now()-interval '1 day',pg_temp.id(1));
INSERT INTO private.access_review_items(campaign_id,subject_id,reviewer_id,role_snapshot,status_snapshot)
VALUES(pg_temp.id(100),pg_temp.id(4),pg_temp.id(1),'moderator','active');
INSERT INTO private.staff_promotion_approvals(approval_id,target_id,requested_by,target_role,target_revision,requester_revision,reason_code)
VALUES(pg_temp.id(101),pg_temp.id(3),pg_temp.id(1),'admin',0,0,'succession');
INSERT INTO private.broadcast_approvals(approval_id,requested_by,requester_revision,title,body,urgency,publication_expires_at)
VALUES(pg_temp.id(102),pg_temp.id(3),0,'Synthetic private draft','This text must not enter the inbox.','info',now()+interval '2 days');
INSERT INTO private.access_review_events(campaign_id,actor_id,kind) VALUES(pg_temp.id(100),pg_temp.id(1),'created');
SELECT is(private.enqueue_governance_notices(),0,'default off: no source fanout');
SELECT ok(NOT has_function_privilege('authenticated','private.enqueue_governance_notices(uuid,integer)','EXECUTE'),'clients cannot forge notices');
SELECT ok(NOT has_table_privilege('authenticated','private.governance_notice_candidates','SELECT'),'private candidate view inaccessible');
SELECT ok(NOT has_function_privilege('anon','public.admin_configure_governance_notices(uuid,boolean)','EXECUTE'),'anonymous rollout denied');
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(3);
SELECT throws_like($$SELECT public.admin_configure_governance_notices(pg_temp.id(200),true)$$,'%not_authorized%','admin cannot enable notices');
SELECT pg_temp.claim(1,'aal1');
SELECT throws_like($$SELECT public.admin_configure_governance_notices(pg_temp.id(200),true)$$,'%aal2_required%','rollout requires MFA');
SELECT pg_temp.claim(1);
SELECT lives_ok($$SELECT public.admin_configure_governance_notices(pg_temp.id(200),true)$$,'active MFA super admin enables');
SELECT lives_ok($$SELECT public.admin_configure_governance_notices(pg_temp.id(200),true)$$,'control retry idempotent');
RESET ROLE;
SELECT is(private.enqueue_governance_notices(),4,'reconcile two review kinds and two pending approvals');
SELECT is(private.enqueue_governance_notices(),0,'duplicate reconciliation creates no events');
SELECT throws_like($$SELECT private.enqueue_governance_notices(NULL,101)$$,'%invalid_limit%','bounded batches');
SELECT private.process_staff_inbox();
SELECT is((SELECT count(*) FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id) WHERE o.source_id=pg_temp.id(101)),1::BIGINT,'promotion only independent super admin');
SELECT is((SELECT count(*) FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id) WHERE o.source_id=pg_temp.id(102)),2::BIGINT,'broadcast review only independent super admins');
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(1);
SELECT is(pg_temp.notices(),3::BIGINT,'reviewer sees two campaign notices and broadcast review');
SELECT is((SELECT count(*) FROM public.admin_staff_inbox_page('assigned','governance')),2::BIGINT,'unclaimed independent reviews are not assigned-to-me');
SELECT is((SELECT count(*) FROM public.admin_staff_inbox_page('urgent','governance')),1::BIGINT,'only overdue review is critical');
SELECT is((SELECT destination FROM public.admin_staff_inbox_page('all','governance') WHERE kind='broadcast_review_requested'),'/broadcasts?source='||pg_temp.id(102),'exact source link');
SELECT public.admin_staff_inbox_set_read(ARRAY(SELECT event_id FROM public.admin_staff_inbox_page('all','governance')),true);
SELECT is((SELECT count(*) FROM public.admin_staff_inbox_page('unread','governance')),0::BIGINT,'read mutation changes only personal unread state');
SELECT pg_temp.claim(2);
SELECT is(pg_temp.notices(),2::BIGINT,'independent approver sees both requests');
SELECT is(jsonb_array_length(public.admin_staff_promotion_register(p_source=>pg_temp.id(101))->'items'),1,'promotion source read is exact');
SELECT is(jsonb_array_length(public.admin_staff_promotion_register(p_source=>pg_temp.id(199))->'items'),0,'missing request never returns unrelated first page');
SELECT throws_like($$SELECT public.admin_staff_promotion_register(now(),pg_temp.id(101),pg_temp.id(101))$$,'%invalid_cursor%','cannot mix source and pagination');
SELECT pg_temp.claim(3);
SELECT is(pg_temp.notices(),0::BIGINT,'admin requester cannot independently review');
SELECT is(jsonb_array_length(public.admin_broadcast_approval_register(p_source=>pg_temp.id(102))->'items'),1,'broadcast exact source read');
SELECT pg_temp.claim(4);
SELECT is(pg_temp.notices(),0::BIGINT,'moderator isolated');
SELECT pg_temp.claim(5);
SELECT is(pg_temp.notices(),0::BIGINT,'support isolated');
SELECT pg_temp.claim(6);
SELECT is(pg_temp.notices(),0::BIGINT,'analyst isolated');
SELECT pg_temp.claim(7);
SELECT is(pg_temp.notices(),0::BIGINT,'auditor isolated');
SELECT pg_temp.claim(8);
SELECT throws_like($$SELECT pg_temp.notices()$$,'%not_authorized%','normal member denied');
RESET ROLE;
SELECT is((SELECT decision FROM private.access_review_items WHERE campaign_id=pg_temp.id(100)),'pending','reading did not retain or revoke access');
UPDATE private.access_review_items SET reviewer_id=pg_temp.id(2) WHERE campaign_id=pg_temp.id(100);
INSERT INTO private.access_review_events(campaign_id,subject_id,actor_id,kind) VALUES(pg_temp.id(100),pg_temp.id(4),pg_temp.id(1),'reassign');
SELECT private.process_staff_inbox();
SELECT ok(NOT private.can_read_staff_event(pg_temp.id(1),'access_review_assigned',pg_temp.id(100)),'old assignee immediately loses notice access');
SELECT ok(private.can_read_staff_event(pg_temp.id(2),'access_review_overdue',pg_temp.id(100)),'new assignee sees overdue work');
UPDATE private.access_review_campaigns SET closed_at=now() WHERE campaign_id=pg_temp.id(100);
SELECT ok(NOT private.can_read_staff_event(pg_temp.id(2),'access_review_assigned',pg_temp.id(100)),'closed campaign hides delivered notice');

-- Approval state changes enqueue in the same transaction as their event.
UPDATE private.staff_promotion_approvals SET state='approved',approved_by=pg_temp.id(2),approver_revision=0,approved_at=now(),version=2 WHERE approval_id=pg_temp.id(101);
INSERT INTO private.staff_promotion_events(approval_id,actor_id,kind,version) VALUES(pg_temp.id(101),pg_temp.id(2),'approve',2);
UPDATE private.broadcast_approvals SET state='approved',approved_by=pg_temp.id(2),approver_revision=0,approved_at=now(),version=2 WHERE approval_id=pg_temp.id(102);
INSERT INTO private.broadcast_approval_events(approval_id,actor_id,kind,version) VALUES(pg_temp.id(102),pg_temp.id(2),'approve',2);
SELECT ok(NOT private.can_read_staff_event(pg_temp.id(2),'promotion_review_requested',pg_temp.id(101)),'completed review hidden');
SELECT ok(private.can_read_staff_event(pg_temp.id(1),'promotion_ready',pg_temp.id(101)),'only requester has execution work');
SELECT ok(NOT private.can_read_staff_event(pg_temp.id(2),'promotion_ready',pg_temp.id(101)),'reviewer cannot execute as requester');

-- Fault injection: subtransaction failure does not duplicate other deliveries.
CREATE FUNCTION pg_temp.delivery_fault() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM private.staff_event_outbox o WHERE o.event_id=NEW.event_id AND o.source_id=pg_temp.id(102) AND o.kind='broadcast_ready') THEN
  RAISE EXCEPTION 'sensitive provider text must not be retained' USING ERRCODE='XX001';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER test_governance_delivery_fault BEFORE INSERT ON private.staff_inbox_deliveries FOR EACH ROW EXECUTE FUNCTION pg_temp.delivery_fault();
SELECT private.process_staff_inbox();
SELECT is((SELECT attempts FROM private.staff_event_outbox WHERE source_id=pg_temp.id(102) AND kind='broadcast_ready'),1,'failed delivery counts attempt');
SELECT is((SELECT last_error_code FROM private.staff_event_outbox WHERE source_id=pg_temp.id(102) AND kind='broadcast_ready'),'XX001','error retains SQLSTATE only');
DROP TRIGGER test_governance_delivery_fault ON private.staff_inbox_deliveries;
-- Exhausted-retry fixture: an operations super admin can recover an admin's
-- ready notice without receiving that notice or gaining publication authority.
UPDATE private.staff_event_outbox SET status='failed',attempts=5 WHERE source_id=pg_temp.id(102) AND kind='broadcast_ready';
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(1);
SELECT is((SELECT count(*) FROM public.admin_staff_inbox_failures() WHERE kind='broadcast_ready'),1::BIGINT,'operations can see failed admin-recipient metadata');
SELECT public.admin_retry_staff_notification(pg_temp.id(202),(SELECT event_id FROM public.admin_staff_inbox_failures() WHERE kind='broadcast_ready'),'transient_resolved');
RESET ROLE;
-- A pause between enqueue and dispatch skips the record. Re-enable must not
-- strand it forever, and must not reset prior read/delivered events.
UPDATE private.staff_inbox_control SET governance_events_enabled=false;
SELECT private.process_staff_inbox();
SELECT is((SELECT status FROM private.staff_event_outbox WHERE source_id=pg_temp.id(102) AND kind='broadcast_ready'),'skipped','disabled source cannot deliver');
UPDATE private.staff_inbox_control SET governance_events_enabled=true;
SELECT is(private.reconcile_governance_notices(),1,'re-enable recovers only the still-actionable skipped record');
SELECT private.process_staff_inbox();
SELECT private.process_staff_inbox();
SELECT is((SELECT count(*) FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id) WHERE o.source_id=pg_temp.id(102) AND o.kind='broadcast_ready'),1::BIGINT,'retry exactly one recipient delivery');
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(3);
SELECT is(pg_temp.notices(),1::BIGINT,'requester receives approved broadcast notice without body');
RESET ROLE;
UPDATE private.staff_promotion_approvals SET expires_at=now()-interval '1 second' WHERE approval_id=pg_temp.id(101);
SELECT ok(NOT private.can_read_staff_event(pg_temp.id(1),'promotion_ready',pg_temp.id(101)),'expired execution hidden');
UPDATE public.users SET account_status='suspended' WHERE user_id=pg_temp.id(2);
SELECT ok(NOT private.can_read_staff_event(pg_temp.id(3),'broadcast_ready',pg_temp.id(102)),'revoked approver invalidates already delivered execution notice');
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(2);
SELECT throws_like($$SELECT pg_temp.notices()$$,'%not_authorized%','suspended staff cannot read old deliveries');
SELECT pg_temp.claim(1);
SELECT lives_ok($$SELECT public.admin_configure_governance_notices(pg_temp.id(201),false)$$,'kill switch available');
SELECT lives_ok($$SELECT public.admin_configure_governance_notices(pg_temp.id(200),true)$$,'old retry receipt does not reenable');
SELECT is(pg_temp.notices(),0::BIGINT,'rollback hides governance notices');
RESET ROLE;
SELECT ok(NOT (SELECT governance_events_enabled FROM private.staff_inbox_control WHERE singleton),'old control replay cannot undo rollback');
SELECT ok(EXISTS(SELECT 1 FROM private.staff_event_outbox WHERE source_id=pg_temp.id(102)),'rollback preserves history');
SELECT is(private.enqueue_governance_notices(),0,'rollback stops producers');
SELECT * FROM finish();
ROLLBACK;
