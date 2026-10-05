-- Staff contacting one member: roles, MFA, idempotency, the three channels,
-- email deliverability, the immutable record, and appeals against warnings.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
SELECT ('1c795000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'contact'||n,'contact'||n,'x','Person','person','contact'||n,r::public.user_role_type,'active',1990
FROM (VALUES(1,'super_admin'),(2,'admin'),(3,'support'),(4,'moderator'),(5,'normal'),(6,'normal'),(7,'normal'))t(n,r);
INSERT INTO auth.users(id,aud,role,email,email_confirmed_at,created_at,updated_at)
SELECT user_id,'authenticated','authenticated',
  CASE anonymous_pseudonym WHEN 'contact5' THEN 'contact5@id.venttly.app' WHEN 'contact6' THEN 'member6@example.test' ELSE NULL END,
  CASE anonymous_pseudonym WHEN 'contact6' THEN now() ELSE NULL END, now(), now()
FROM public.users WHERE anonymous_pseudonym LIKE 'contact%';
INSERT INTO auth.sessions(id,user_id,created_at,updated_at,aal)
SELECT user_id,user_id,now(),now(),'aal2' FROM public.users WHERE anonymous_pseudonym LIKE 'contact%';
UPDATE public.users SET recovery_email='seven@example.test', recovery_email_verified=true WHERE anonymous_pseudonym='contact7';
SET session_replication_role=origin;
CREATE FUNCTION pg_temp.id(n INT) RETURNS UUID LANGUAGE sql AS $$SELECT ('1c795000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID$$;
CREATE FUNCTION pg_temp.claim(n INT,aal TEXT DEFAULT 'aal2') RETURNS VOID LANGUAGE sql AS $$
 SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.id(n),'session_id',pg_temp.id(n),'role','authenticated','aal',aal)::TEXT,true)::TEXT;
$$;

SELECT ok(NOT has_table_privilege('authenticated','private.member_communications','SELECT'),'clients cannot read the communications record');
SELECT ok(NOT has_function_privilege('anon','public.admin_message_member(uuid,uuid,text,text)','EXECUTE'),'anonymous cannot message');
SELECT ok(NOT has_function_privilege('authenticated','private.member_email_address(uuid)','EXECUTE'),'addresses are not exposed');

SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(4);
SELECT throws_like($$SELECT public.admin_message_member(pg_temp.id(100),pg_temp.id(5),'Hello there','A message long enough.')$$,'%not_authorized%','moderator cannot message');
SELECT pg_temp.claim(5);
SELECT throws_like($$SELECT public.admin_message_member(pg_temp.id(100),pg_temp.id(6),'Hello there','A message long enough.')$$,'%not_authorized%','members cannot message');
SELECT pg_temp.claim(3,'aal1');
SELECT throws_like($$SELECT public.admin_message_member(pg_temp.id(100),pg_temp.id(5),'Hello there','A message long enough.')$$,'%aal2_required%','sending requires MFA');
SELECT pg_temp.claim(3);
SELECT throws_like($$SELECT public.admin_message_member(pg_temp.id(100),pg_temp.id(5),'Hi','A message long enough.')$$,'%invalid_input%','subject too short');
SELECT throws_like($$SELECT public.admin_message_member(pg_temp.id(101),pg_temp.id(3),'Hello there','A message long enough.')$$,'%invalid_input%','cannot message yourself');
SELECT throws_like($$SELECT public.admin_message_member(pg_temp.id(102),pg_temp.id(99),'Hello there','A message long enough.')$$,'%not_found%','unknown member');
SELECT lives_ok($$SELECT public.admin_message_member(pg_temp.id(103),pg_temp.id(5),'Checking in','We noticed you asked for help.')$$,'support sends an in-app message');
SELECT lives_ok($$SELECT public.admin_message_member(pg_temp.id(103),pg_temp.id(5),'Checking in','We noticed you asked for help.')$$,'retry is idempotent');
SELECT throws_like($$SELECT public.admin_message_member(pg_temp.id(103),pg_temp.id(5),'Checking in','A different body this time.')$$,'%idempotency_payload_mismatch%','reused operation with new text is refused');
SELECT throws_like($$SELECT public.admin_warn_member(pg_temp.id(104),pg_temp.id(5),'P-1','Harassing other members.',true)$$,'%not_authorized%','support cannot warn');
SELECT is((public.admin_member_contact_options(pg_temp.id(5))->>'email_available')::BOOLEAN,false,'synthetic address is not an email');
SELECT is(public.admin_member_contact_options(pg_temp.id(6))->>'email_hint','m•••@example.test','confirmed auth email is offered masked');
SELECT is(public.admin_member_contact_options(pg_temp.id(7))->>'email_hint','s•••@example.test','verified recovery email is offered');
SELECT throws_like($$SELECT public.admin_email_member(pg_temp.id(105),pg_temp.id(5),'Checking in','We noticed you asked for help.')$$,'%email_unavailable%','no email for anonymous members');
SELECT lives_ok($$SELECT public.admin_email_member(pg_temp.id(106),pg_temp.id(6),'Checking in','We noticed you asked for help.')$$,'email queued for a real address');
SELECT pg_temp.claim(2);
SELECT lives_ok($$SELECT public.admin_warn_member(pg_temp.id(107),pg_temp.id(5),'P-1','Harassing other members.',true)$$,'admin issues a formal warning');
RESET ROLE;

SELECT is((SELECT count(*) FROM public.notifications WHERE user_id=pg_temp.id(5) AND kind='system' AND payload->>'source'='venttly_team'),1::BIGINT,'one in-app message despite the retry');
SELECT is((SELECT payload->>'action' FROM public.notifications WHERE user_id=pg_temp.id(5) AND kind='moderation_action'),'case_user_warned','warning reaches Appeals & warnings');
SELECT is((SELECT to_address FROM public.email_outbox WHERE user_id=pg_temp.id(6) AND template='staff_message'),'member6@example.test','email addressed explicitly');
SELECT is((SELECT count(*) FROM public.audit_log WHERE target_id=pg_temp.id(5) AND action IN ('member.message','member.warning')),2::BIGINT,'both sends audited');
SELECT throws_like($$UPDATE private.member_communications SET body='edited' WHERE member_id=pg_temp.id(5)$$,'%immutable%','what was said cannot be edited');

SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(1);
SELECT is((SELECT count(*) FROM public.admin_member_communications(pg_temp.id(5))),2::BIGINT,'profile lists message and warning');
SELECT pg_temp.claim(5);
SELECT lives_ok($$SELECT public.submit_account_appeal((SELECT notification_id FROM public.notifications WHERE user_id=pg_temp.id(5) AND kind='moderation_action'),'I was defending a friend.')$$,'member appeals the warning');
RESET ROLE;
CREATE TEMP TABLE appeal_under_review AS SELECT appeal_id FROM public.moderation_appeals WHERE appellant_id=pg_temp.id(5);
GRANT SELECT ON appeal_under_review TO authenticated;
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(2);
SELECT throws_like($$SELECT public.admin_decide_appeal((SELECT appeal_id FROM appeal_under_review),'overturned','Reviewed.')$$,'%took the decision%','the issuer cannot review the appeal');
SELECT pg_temp.claim(1);
SELECT lives_ok($$SELECT public.admin_decide_appeal((SELECT appeal_id FROM appeal_under_review),'overturned','On review the warning was not warranted.')$$,'independent reviewer overturns');
RESET ROLE;
SELECT ok((SELECT rescinded_at IS NOT NULL FROM private.member_communications WHERE member_id=pg_temp.id(5) AND channel='warning'),'overturning rescinds the warning');
SELECT is((SELECT count(*) FROM public.notifications WHERE user_id=pg_temp.id(5) AND payload->>'action'='account_reinstated'),0::BIGINT,'no false reinstatement notice');

SELECT * FROM finish();
ROLLBACK;
