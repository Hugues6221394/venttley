-- Two-way support: members start and reply, staff answer, the owner is
-- alerted, retries are safe, other members see nothing, and what was said
-- stays as it was said.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
SELECT ('5c0a7000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'convo'||n,'x','x','Convo '||n,'convo '||n,'convo'||n,r::public.user_role_type,s,1990
FROM (VALUES(1,'support','active'),(2,'support','active'),(3,'normal','active'),(4,'normal','active'),(5,'normal','suspended'),(6,'moderator','active'))t(n,r,s);
INSERT INTO auth.users(id,aud,role,created_at,updated_at)
SELECT user_id,'authenticated','authenticated',now(),now() FROM public.users WHERE anonymous_pseudonym LIKE 'convo%';
INSERT INTO auth.sessions(id,user_id,created_at,updated_at,aal)
SELECT user_id,user_id,now(),now(),'aal2' FROM public.users WHERE anonymous_pseudonym LIKE 'convo%';
SET session_replication_role=origin;
UPDATE private.staff_inbox_control SET enabled=true WHERE singleton;
CREATE FUNCTION pg_temp.id(n INT) RETURNS UUID LANGUAGE sql AS $$SELECT ('5c0a7000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID$$;
CREATE FUNCTION pg_temp.op(n INT) RETURNS UUID LANGUAGE sql AS $$SELECT ('5c0a7000-1000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID$$;
CREATE FUNCTION pg_temp.as_user(n INT,aal TEXT DEFAULT 'aal2') RETURNS VOID LANGUAGE sql AS $$
 SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.id(n),'session_id',pg_temp.id(n),'role','authenticated','aal',aal)::TEXT,true)::TEXT;
$$;
CREATE TEMP TABLE ids(name TEXT PRIMARY KEY, id UUID);
GRANT ALL ON ids TO authenticated;

SELECT ok(NOT has_table_privilege('authenticated','private.support_messages','SELECT'),'clients cannot read messages directly');
SELECT ok(NOT has_function_privilege('anon','public.member_start_support(uuid,text,text,text)','EXECUTE'),'anonymous cannot start a conversation');
SELECT ok(NOT has_function_privilege('anon','public.admin_reply_support(uuid,uuid,text,boolean)','EXECUTE'),'anonymous cannot reply as staff');

SET LOCAL ROLE authenticated;
-- A member starts a conversation.
SELECT pg_temp.as_user(3);
SELECT throws_like($$SELECT public.member_start_support(pg_temp.op(1),'billing','Help me','Something is wrong')$$,'%unknown category%','unknown category refused');
SELECT throws_like($$SELECT public.member_start_support(pg_temp.op(1),'technical','Hi','Something is wrong')$$,'%subject%','short subject refused');
INSERT INTO ids SELECT 'started', public.member_start_support(pg_temp.op(1),'technical','App will not load','It closes on launch.');
SELECT is(public.member_start_support(pg_temp.op(1),'technical','App will not load','It closes on launch.'),(SELECT id FROM ids WHERE name='started'),'retry returns the same conversation');
SELECT is((SELECT count(*)::INT FROM public.member_support_conversations()),1,'member sees one conversation');
SELECT is((SELECT status FROM public.member_support_conversations()),'open','new conversation is open');
SELECT is(jsonb_array_length(public.member_support_thread((SELECT id FROM ids WHERE name='started'))->'messages'),1,'thread holds the first message');

-- Another member sees nothing and cannot reply.
SELECT pg_temp.as_user(4);
SELECT is((SELECT count(*)::INT FROM public.member_support_conversations()),0,'other member sees no conversations');
SELECT throws_like($$SELECT public.member_support_thread((SELECT id FROM ids WHERE name='started'))$$,'%not_found%','other member cannot open it');
SELECT throws_like($$SELECT public.member_reply_support(pg_temp.op(2),'Me too',(SELECT id FROM ids WHERE name='started'))$$,'%not_found%','other member cannot reply');

-- Staff read and reply.
SELECT pg_temp.as_user(6);
SELECT throws_like($$SELECT public.admin_support_conversation((SELECT id FROM ids WHERE name='started'))$$,'%not_authorized%','moderators cannot read support conversations');
SELECT pg_temp.as_user(1,'aal1');
SELECT throws_like($$SELECT public.admin_reply_support(pg_temp.op(3),(SELECT id FROM ids WHERE name='started'),'Try reinstalling.')$$,'%aal2%','staff reply requires MFA');
SELECT pg_temp.as_user(1);
SELECT is(public.admin_support_conversation((SELECT id FROM ids WHERE name='started'))->>'member_pseudonym','convo3','staff see who is asking');
SELECT lives_ok($$SELECT public.admin_reply_support(pg_temp.op(3),(SELECT id FROM ids WHERE name='started'),'Try reinstalling.')$$,'staff reply sent');
SELECT lives_ok($$SELECT public.admin_reply_support(pg_temp.op(3),(SELECT id FROM ids WHERE name='started'),'Try reinstalling.')$$,'staff reply retry is idempotent');
RESET ROLE;
SELECT is((SELECT count(*)::INT FROM private.support_messages WHERE support_case_id=(SELECT id FROM ids WHERE name='started') AND author_kind='staff'),1,'one staff message despite the retry');
SELECT is((SELECT status FROM private.support_cases WHERE support_case_id=(SELECT id FROM ids WHERE name='started')),'waiting_member','case waits on the member');
SELECT is((SELECT assigned_to FROM private.support_cases WHERE support_case_id=(SELECT id FROM ids WHERE name='started')),pg_temp.id(1),'replying takes ownership');
SELECT is((SELECT payload->>'support_case_id' FROM public.notifications WHERE user_id=pg_temp.id(3) AND kind='system'),(SELECT id::TEXT FROM ids WHERE name='started'),'member is notified with the conversation');

-- The member sees the reply, answers, and the owner is alerted.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(3);
SELECT is((SELECT unread FROM public.member_support_conversations()),true,'reply is unread');
SELECT is((SELECT status FROM public.member_support_conversations()),'replied','member sees the team replied');
SELECT is(public.member_support_thread((SELECT id FROM ids WHERE name='started'))->'messages'->1->>'from','venttly','staff appear as the Venttly team');
SELECT is((SELECT unread FROM public.member_support_conversations()),false,'opening the thread marks it read');
SELECT lives_ok($$SELECT public.member_reply_support(pg_temp.op(4),'Still closing.',(SELECT id FROM ids WHERE name='started'))$$,'member replies');
RESET ROLE;
SELECT is((SELECT status FROM private.support_cases WHERE support_case_id=(SELECT id FROM ids WHERE name='started')),'assigned','reply puts the case back with its owner');
SELECT is((SELECT intended_recipient FROM private.staff_event_outbox WHERE source_id=(SELECT id FROM ids WHERE name='started') AND kind='support_member_replied'),pg_temp.id(1),'owner gets a member-replied alert');

-- Resolved, then picked up again; closed cannot be.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(1);
SELECT lives_ok($$SELECT public.admin_reply_support(pg_temp.op(5),(SELECT id FROM ids WHERE name='started'),'Fixed in the next update.',true)$$,'staff reply and resolve');
SELECT pg_temp.as_user(3);
SELECT lives_ok($$SELECT public.member_reply_support(pg_temp.op(6),'Thanks, but it happened again.',(SELECT id FROM ids WHERE name='started'))$$,'member reopens a resolved conversation');
RESET ROLE;
SELECT ok(EXISTS(SELECT 1 FROM private.support_case_events WHERE support_case_id=(SELECT id FROM ids WHERE name='started') AND event_kind='reopened'),'reopen is recorded');
UPDATE private.support_cases SET status='closed',resolved_at=now() WHERE support_case_id=(SELECT id FROM ids WHERE name='started');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(3);
SELECT throws_like($$SELECT public.member_reply_support(pg_temp.op(7),'Hello?',(SELECT id FROM ids WHERE name='started'))$$,'%conversation_closed%','closed conversation refuses replies');

-- Replying to a staff message opens a thread owned by the sender.
SELECT pg_temp.as_user(2);
INSERT INTO ids SELECT 'message', public.admin_message_member(pg_temp.op(8),pg_temp.id(5),'Checking in','We saw your report and wanted to follow up.');
SELECT pg_temp.as_user(5);
SELECT is((SELECT communication_id FROM public.member_support_conversations()),(SELECT id FROM ids WHERE name='message'),'suspended member sees the staff message');
SELECT is(public.member_support_thread(NULL,(SELECT id FROM ids WHERE name='message'))->'messages'->0->>'from','venttly','staff message reads as from Venttly');
INSERT INTO ids SELECT 'thread', public.member_reply_support(pg_temp.op(9),'Thank you, it is better now.',NULL,(SELECT id FROM ids WHERE name='message'));
SELECT is((SELECT count(*)::INT FROM public.member_support_conversations()),1,'staff message and its thread are one entry');
SELECT is(jsonb_array_length(public.member_support_thread((SELECT id FROM ids WHERE name='thread'))->'messages'),2,'thread starts with the staff message');
RESET ROLE;
SELECT is((SELECT assigned_to FROM private.support_cases WHERE support_case_id=(SELECT id FROM ids WHERE name='thread')),pg_temp.id(2),'sender owns the thread');
SELECT is((SELECT count(*)::INT FROM private.staff_event_outbox WHERE source_id=(SELECT id FROM ids WHERE name='thread') AND kind='support_assigned'),0,'no duplicate assignment alert');
SELECT is((SELECT count(*)::INT FROM private.staff_event_outbox WHERE source_id=(SELECT id FROM ids WHERE name='thread') AND kind='support_member_replied'),1,'sender gets the member-replied alert');

-- Limits and records.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(4);
SELECT public.member_start_support(pg_temp.op(10+n),'other','Question '||n,'Body text here.') FROM generate_series(1,3) n;
SELECT throws_like($$SELECT public.member_start_support(pg_temp.op(20),'other','Question 4','Body text here.')$$,'%too_many_open%','at most three open conversations');
RESET ROLE;
SELECT throws_like($$UPDATE private.support_messages SET body='edited' WHERE support_case_id=(SELECT id FROM ids WHERE name='thread') AND author_kind='staff'$$,'%immutable%','messages cannot be edited');
UPDATE public.users SET deactivated_at=now() WHERE user_id=pg_temp.id(4);
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(4);
SELECT throws_like($$SELECT * FROM public.member_support_conversations()$$,'%not_authorized%','deactivated accounts cannot use support');
RESET ROLE;
UPDATE private.support_cases SET member_id=NULL WHERE support_case_id=(SELECT id FROM ids WHERE name='thread');
SELECT is((SELECT body FROM private.support_messages WHERE support_case_id=(SELECT id FROM ids WHERE name='thread') AND author_kind='member'),'[removed with the account]','member words are removed with the account');
SELECT isnt((SELECT body FROM private.support_messages WHERE support_case_id=(SELECT id FROM ids WHERE name='thread') AND author_kind='staff'),'[removed with the account]','staff words stay on record');

SELECT * FROM finish();
ROLLBACK;
