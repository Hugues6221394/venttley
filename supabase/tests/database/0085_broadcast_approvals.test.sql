-- PREPARED, NOT RUN. Disposable DB only, after draft/dependency promotion.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
SELECT ('1b792000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'broadcastpilot'||n,'broadcastpilot'||n,'x','Broadcast Operator','broadcast operator','broadcastpilot'||n,r::public.user_role_type,'active',1990
FROM (VALUES(1,'super_admin'),(2,'super_admin'),(3,'admin'),(4,'moderator'),(5,'support'),(6,'analyst'),(7,'read_only_auditor'))t(n,r);
INSERT INTO auth.users(id,aud,role,created_at,updated_at)
SELECT user_id,'authenticated','authenticated',now(),now() FROM public.users WHERE anonymous_pseudonym LIKE 'broadcastpilot%';
INSERT INTO auth.sessions(id,user_id,created_at,updated_at,aal)
SELECT user_id,user_id,now(),now(),'aal2' FROM public.users WHERE anonymous_pseudonym LIKE 'broadcastpilot%';
SET session_replication_role=origin;
CREATE FUNCTION pg_temp.claim(n INT,aal TEXT DEFAULT 'aal2') RETURNS VOID LANGUAGE sql AS $$
 SELECT set_config('request.jwt.claims',jsonb_build_object('sub','1b792000-0000-4000-8000-'||lpad(n::TEXT,12,'0'),
 'session_id','1b792000-0000-4000-8000-'||lpad(n::TEXT,12,'0'),'role','authenticated','aal',aal)::TEXT,true)::TEXT;
$$;
CREATE FUNCTION pg_temp.request(op UUID DEFAULT gen_random_uuid(),title TEXT DEFAULT 'Synthetic broadcast') RETURNS UUID LANGUAGE sql AS $$
 SELECT public.admin_request_broadcast_approval(op,title,'Public notice for a synthetic test.','info',now()+interval '2 days');
$$;
CREATE FUNCTION pg_temp.command(cmd TEXT,v BIGINT,op UUID DEFAULT gen_random_uuid()) RETURNS VOID LANGUAGE sql AS $$
 SELECT public.admin_broadcast_approval_command(op,current_setting('test.broadcast')::UUID,v,cmd);
$$;
SELECT ok(NOT has_table_privilege('authenticated','private.broadcast_approval_permits','INSERT'),'no forged permit');
SELECT ok(NOT has_table_privilege('anon','private.broadcast_approvals','SELECT'),'private draft unreadable by anonymous clients');
SELECT ok(NOT has_function_privilege('authenticated','public.service_configure_broadcast_approvals(uuid,boolean)','EXECUTE'),'staff cannot turn off enforcement');
SELECT ok(NOT has_function_privilege('anon','public.admin_broadcast_approval_register(timestamptz,uuid,uuid)','EXECUTE'),'anonymous register denied');
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(3);
SELECT is(public.admin_broadcast_approval_register()->>'enabled','false','default off');
SELECT throws_like($$SELECT pg_temp.request()$$,'%broadcast_approvals_disabled%','flag refuses draft writes');
RESET ROLE;
SELECT public.service_configure_broadcast_approvals('1b792000-1000-4000-8000-000000000001',true);
SELECT lives_ok($$SELECT public.service_configure_broadcast_approvals('1b792000-1000-4000-8000-000000000001',true)$$,'control retry');
SELECT throws_like($$SELECT public.service_configure_broadcast_approvals('1b792000-1000-4000-8000-000000000001',false)$$,'%idempotency_payload_mismatch%','control retry cannot change intent');
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(3,'aal1');
SELECT throws_like($$SELECT pg_temp.request()$$,'%aal2_required%','request requires MFA');
SELECT pg_temp.claim(3);
SELECT throws_like($$SELECT public.admin_send_broadcast('Bypass','Body','info','{"scope":"all"}')$$,'%broadcast_approval_required%','legacy API cannot publish');
SELECT throws_like($$SELECT public.admin_send_broadcast('Bypass','Body','info','{"scope":"tribe","value":"private"}')$$,'%broadcast_approval_required%','targeted legacy send cannot bypass');
SELECT throws_like($$SELECT pg_temp.request(gen_random_uuid(),'<script>')$$,'%invalid_broadcast_payload%','markup rejected');
SELECT throws_like($$SELECT public.admin_request_broadcast_approval(gen_random_uuid(),'Title','Body','info',now()-interval '1 second')$$,'%invalid_broadcast_payload%','past deadline rejected');
SELECT set_config('test.broadcast',pg_temp.request('1b792000-1000-4000-8000-000000000002')::TEXT,true);
SELECT is(pg_temp.request('1b792000-1000-4000-8000-000000000002')::TEXT,current_setting('test.broadcast'),'draft retry same record');
SELECT throws_like($$SELECT pg_temp.request('1b792000-1000-4000-8000-000000000002','Changed')$$,'%idempotency_payload_mismatch%','changed payload cannot reuse key');
SELECT throws_like($$SELECT pg_temp.command('publish',1)$$,'%not_authorized%','unapproved draft cannot publish');
SELECT throws_like($$SELECT pg_temp.command('approve',1)$$,'%not_authorized%','admin cannot approve');
RESET ROLE;
SELECT is((SELECT count(*)::INT FROM public.broadcasts WHERE title='Synthetic broadcast'),0,'draft not in public storage');
SELECT throws_like($$UPDATE private.broadcast_approvals SET body='Changed' WHERE approval_id=current_setting('test.broadcast')::UUID$$,'%broadcast_payload_immutable%','payload frozen even before approval');
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(1,'aal1');
SELECT throws_like($$SELECT pg_temp.command('approve',1)$$,'%aal2_required%','reviewer MFA');
SELECT pg_temp.claim(1);
SELECT lives_ok($$SELECT pg_temp.command('approve',1)$$,'independent super-admin approval');
SELECT throws_like($$SELECT pg_temp.command('publish',2)$$,'%not_authorized%','reviewer cannot publish as requester');
SELECT pg_temp.claim(3);
SELECT throws_like($$SELECT pg_temp.command('publish',1)$$,'%broadcast_conflict%','stale version refused');
SELECT lives_ok($$SELECT pg_temp.command('publish',2,'1b792000-1000-4000-8000-000000000003')$$,'approved publication');
SELECT lives_ok($$SELECT pg_temp.command('publish',2,'1b792000-1000-4000-8000-000000000003')$$,'retry once');
RESET ROLE;
SELECT is((SELECT count(*)::INT FROM public.broadcasts WHERE title='Synthetic broadcast'),1,'exactly one publication');
SELECT is((SELECT audience FROM public.broadcasts WHERE title='Synthetic broadcast'),' {"scope":"all"}'::JSONB,'fixed global audience');
SELECT is((SELECT count(*)::INT FROM private.broadcast_approval_permits),0,'ephemeral permits gone');
SELECT throws_like($$UPDATE public.broadcasts SET body='Changed' WHERE title='Synthetic broadcast'$$,'%broadcast_approval_required%','post-publication mutation refused');
SELECT lives_ok($$UPDATE public.broadcasts SET delivered_count=1 WHERE title='Synthetic broadcast'$$,'existing counter updates allowed');
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
SET LOCAL ROLE anon;
SELECT is((SELECT count(*)::INT FROM public.broadcasts WHERE title='Synthetic broadcast'),1,'approved active global message visible');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(3);
SELECT lives_ok($$SELECT public.admin_stop_approved_broadcast('1b792000-1000-4000-8000-000000000004',current_setting('test.broadcast')::UUID)$$,'emergency stop');
SELECT lives_ok($$SELECT public.admin_stop_approved_broadcast('1b792000-1000-4000-8000-000000000004',current_setting('test.broadcast')::UUID)$$,'stop retry');
RESET ROLE;
SELECT throws_like($$UPDATE public.broadcasts SET is_active=true WHERE title='Synthetic broadcast'$$,'%broadcast_approval_required%','reactivation cannot bypass fresh approval');
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
SET LOCAL ROLE anon;
SELECT is((SELECT count(*)::INT FROM public.broadcasts WHERE title='Synthetic broadcast'),0,'stopped message hidden');
RESET ROLE;
SELECT throws_like($$DELETE FROM private.broadcast_approval_events WHERE approval_id=current_setting('test.broadcast')::UUID$$,'%immutable_operational_record%','audit events immutable');
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(1);
SELECT set_config('test.broadcast',pg_temp.request()::TEXT,true);
SELECT throws_like($$SELECT pg_temp.command('approve',1)$$,'%independent_approver_required%','super admin cannot self-approve');
SELECT pg_temp.claim(2);
SELECT pg_temp.command('approve',1);
RESET ROLE;
UPDATE public.users SET account_status='suspended' WHERE anonymous_pseudonym='broadcastpilot2';
UPDATE public.users SET account_status='active' WHERE anonymous_pseudonym='broadcastpilot2';
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(1);
SELECT throws_like($$SELECT pg_temp.command('publish',2)$$,'%broadcast_authority_changed%','authority restored still invalidates approval');
SELECT pg_temp.command('cancel',2);
SELECT throws_like($$SELECT pg_temp.command('publish',3)$$,'%broadcast_conflict%','cancelled request cannot publish');
RESET ROLE;
-- Expired fixtures are inserted by the disposable test owner, never by an RPC.
INSERT INTO private.broadcast_approvals(approval_id,requested_by,requester_revision,title,body,urgency,publication_expires_at,expires_at)
VALUES('1b792000-2000-4000-8000-000000000001','1b792000-0000-4000-8000-000000000001',0,'Expired review','Synthetic','info',now()+interval '2 days',now()-interval '1 second'),
('1b792000-2000-4000-8000-000000000002','1b792000-0000-4000-8000-000000000001',0,'Expired message','Synthetic','info',now()-interval '1 second',now()+interval '1 day');
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(2);
SELECT throws_like($$SELECT public.admin_broadcast_approval_command(gen_random_uuid(),'1b792000-2000-4000-8000-000000000001',1,'approve')$$,'%broadcast_expired%','expired review refused');
SELECT throws_like($$SELECT public.admin_broadcast_approval_command(gen_random_uuid(),'1b792000-2000-4000-8000-000000000002',1,'approve')$$,'%broadcast_expired%','expired message refused');
SELECT pg_temp.claim(4);
SELECT throws_like($$SELECT public.admin_broadcast_approval_register()$$,'%not_authorized%','moderator denied');
SELECT pg_temp.claim(5);
SELECT throws_like($$SELECT public.admin_broadcast_approval_register()$$,'%not_authorized%','support denied');
SELECT pg_temp.claim(6);
SELECT throws_like($$SELECT public.admin_broadcast_approval_register()$$,'%not_authorized%','analyst denied');
SELECT pg_temp.claim(7);
SELECT throws_like($$SELECT public.admin_broadcast_approval_register()$$,'%not_authorized%','auditor denied');
RESET ROLE;
DELETE FROM auth.sessions WHERE user_id='1b792000-0000-4000-8000-000000000003';
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(3);
SELECT throws_like($$SELECT public.admin_broadcast_approval_register()$$,'%broadcast_session_unavailable%','revoked live session denied');
RESET ROLE;
SELECT public.service_configure_broadcast_approvals(gen_random_uuid(),false);
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(1);
SELECT throws_like($$SELECT pg_temp.request()$$,'%broadcast_approvals_disabled%','rollback stops new requests');
RESET ROLE;
SELECT ok(EXISTS(SELECT 1 FROM private.broadcast_approvals),'rollback retains records');
SELECT * FROM finish();
ROLLBACK;
