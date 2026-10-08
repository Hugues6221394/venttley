-- Broadcasts reach members: everyone or one tribe, now or later, in batches,
-- never twice, never to accounts that are leaving, and a withdrawn broadcast
-- leaves the inboxes it reached.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
-- Earlier rows (fixtures, seeds) are not part of this test's audience.
UPDATE public.users SET account_status='suspended' WHERE account_status='active';
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year,deletion_requested_at)
SELECT ('b0ad0000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'bcast'||n,'x','x','Bcast '||n,'bcast '||n,'bcast'||n,r::public.user_role_type,s,1990,
       CASE WHEN n=6 THEN now() END
FROM (VALUES(1,'admin','active'),(2,'moderator','active'),(3,'normal','active'),(4,'normal','active'),(5,'normal','suspended'),(6,'normal','active'),(7,'normal','active'))t(n,r,s);
INSERT INTO auth.users(id,aud,role,created_at,updated_at)
SELECT user_id,'authenticated','authenticated',now(),now() FROM public.users WHERE anonymous_pseudonym LIKE 'bcast%';
INSERT INTO auth.sessions(id,user_id,created_at,updated_at,aal)
SELECT user_id,user_id,now(),now(),'aal2' FROM public.users WHERE anonymous_pseudonym LIKE 'bcast%';
INSERT INTO public.tribes(tribe_id,name,slug) VALUES('b0ad0000-2000-4000-8000-000000000001','Night owls','night-owls-bcast');
INSERT INTO public.tribe_members(tribe_id,user_id) VALUES
 ('b0ad0000-2000-4000-8000-000000000001','b0ad0000-0000-4000-8000-000000000003'),
 ('b0ad0000-2000-4000-8000-000000000001','b0ad0000-0000-4000-8000-000000000005');
SET session_replication_role=origin;
CREATE FUNCTION pg_temp.id(n INT) RETURNS UUID LANGUAGE sql AS $$SELECT ('b0ad0000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID$$;
CREATE FUNCTION pg_temp.op(n INT) RETURNS UUID LANGUAGE sql AS $$SELECT ('b0ad0000-1000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID$$;
CREATE FUNCTION pg_temp.as_user(n INT,aal TEXT DEFAULT 'aal2') RETURNS VOID LANGUAGE sql AS $$
 SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.id(n),'session_id',pg_temp.id(n),'role','authenticated','aal',aal)::TEXT,true)::TEXT;
$$;
CREATE FUNCTION pg_temp.inbox(n INT) RETURNS INT LANGUAGE sql AS $$
 SELECT count(*)::INT FROM public.notifications WHERE user_id=pg_temp.id(n) AND kind='admin_broadcast'$$;
CREATE TEMP TABLE ids(name TEXT PRIMARY KEY, id UUID);
GRANT ALL ON ids TO authenticated;

SELECT ok(NOT has_table_privilege('authenticated','private.broadcast_deliveries','SELECT'),'clients cannot read delivery state');
SELECT ok(NOT has_function_privilege('anon','public.admin_publish_broadcast(uuid,text,text,text,uuid,timestamptz,timestamptz)','EXECUTE'),'anonymous cannot publish');
SELECT ok(NOT has_function_privilege('authenticated','private.deliver_broadcasts(integer)','EXECUTE'),'clients cannot run delivery');
SELECT is((SELECT jobname FROM cron.job WHERE jobname='broadcast-delivery'),'broadcast-delivery','delivery is scheduled');

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(2);
SELECT throws_like($$SELECT public.admin_publish_broadcast(pg_temp.op(1),'Hello','World','info')$$,'%not_authorized%','moderators cannot publish');
SELECT pg_temp.as_user(1,'aal1');
SELECT throws_like($$SELECT public.admin_publish_broadcast(pg_temp.op(1),'Hello','World','info')$$,'%aal2%','publishing requires MFA');
SELECT pg_temp.as_user(1);
SELECT throws_like($$SELECT public.admin_publish_broadcast(pg_temp.op(1),' Hello','World','info')$$,'%invalid_broadcast_payload%','untrimmed title refused');
SELECT throws_like($$SELECT public.admin_publish_broadcast(pg_temp.op(1),'Hello','World','info',NULL,now()-interval '1 minute')$$,'%invalid_schedule%','a schedule in the past is refused');
SELECT throws_like($$SELECT public.admin_publish_broadcast(pg_temp.op(1),'Hello','World','info',gen_random_uuid())$$,'%tribe_not_found%','unknown tribe refused');
SELECT is((public.admin_broadcast_audience()->>'members')::INT,5,'everyone means active accounts not leaving');
SELECT is((public.admin_broadcast_audience('b0ad0000-2000-4000-8000-000000000001')->>'members')::INT,1,'a tribe audience counts its active members');
INSERT INTO ids SELECT 'all', public.admin_publish_broadcast(pg_temp.op(1),'Maintenance tonight','We will be back by 2am.','info');
SELECT is(public.admin_publish_broadcast(pg_temp.op(1),'Maintenance tonight','We will be back by 2am.','info'),(SELECT id FROM ids WHERE name='all'),'retry returns the same broadcast');
INSERT INTO ids SELECT 'tribe', public.admin_publish_broadcast(pg_temp.op(2),'Owls meetup','Thursday at 9.','info','b0ad0000-2000-4000-8000-000000000001');
INSERT INTO ids SELECT 'later', public.admin_publish_broadcast(pg_temp.op(3),'Next week','Coming soon.','info',NULL,now()+interval '2 days');
RESET ROLE;

SELECT is((SELECT count(*)::INT FROM public.broadcasts WHERE broadcast_id IN (SELECT id FROM ids)),3,'three broadcasts stored');
SELECT is((SELECT state FROM private.broadcast_deliveries WHERE broadcast_id=(SELECT id FROM ids WHERE name='all')),'waiting','delivery waits for the job');

-- Batches of two: the everyone broadcast needs more than one run.
SELECT is(private.deliver_broadcasts(2),2,'first run delivers one batch');
SELECT is((SELECT state FROM private.broadcast_deliveries WHERE broadcast_id=(SELECT id FROM ids WHERE name='all')),'delivering','still delivering after one batch');
SELECT private.deliver_broadcasts(100);
SELECT private.deliver_broadcasts(100);
SELECT is((SELECT state FROM private.broadcast_deliveries WHERE broadcast_id=(SELECT id FROM ids WHERE name='all')),'delivered','everyone broadcast finished');
SELECT is((SELECT delivered_count FROM public.broadcasts WHERE broadcast_id=(SELECT id FROM ids WHERE name='all')),5,'delivered to the five eligible accounts');
SELECT is(pg_temp.inbox(3),2,'tribe member got both');
SELECT is(pg_temp.inbox(4),1,'non-member got only the everyone broadcast');
SELECT is(pg_temp.inbox(5),0,'suspended account got nothing');
SELECT is(pg_temp.inbox(6),0,'account being deleted got nothing');
SELECT is((SELECT count(*)::INT FROM public.notifications WHERE subject_id=(SELECT id FROM ids WHERE name='all')),5,'no member got it twice');
SELECT is((SELECT payload->>'title' FROM public.notifications WHERE user_id=pg_temp.id(4) AND kind='admin_broadcast'),'Maintenance tonight','the notification carries the title');
SELECT is((SELECT count(*)::INT FROM public.notifications WHERE subject_id=(SELECT id FROM ids WHERE name='later')),0,'a scheduled broadcast waits for its time');

-- Broadcasts from before delivery existed are never sent.
SET session_replication_role=replica;
INSERT INTO public.broadcasts(broadcast_id,title,body,urgency,audience,sent_at) VALUES('b0ad0000-3000-4000-8000-000000000001','Old','Old','info','{"scope":"all"}',now());
INSERT INTO private.broadcast_deliveries(broadcast_id,state) VALUES('b0ad0000-3000-4000-8000-000000000001','predates_delivery');
SET session_replication_role=origin;
SELECT private.deliver_broadcasts(100);
SELECT is((SELECT count(*)::INT FROM public.notifications WHERE subject_id='b0ad0000-3000-4000-8000-000000000001'),0,'an old broadcast is not delivered');

-- An audience that cannot be resolved is never widened to everyone.
INSERT INTO public.broadcasts(title,body,urgency,audience,sent_at) VALUES('Region','x','info','{"scope":"region","value":"RW"}',now());
SELECT private.deliver_broadcasts(100);
SELECT is((SELECT count(*)::INT FROM public.notifications n JOIN public.broadcasts b ON b.broadcast_id=n.subject_id WHERE b.title='Region'),0,'unknown scope delivers to nobody');

-- Withdraw removes it from inboxes.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(1);
SELECT lives_ok($$SELECT public.admin_withdraw_broadcast(pg_temp.op(4),(SELECT id FROM ids WHERE name='all'))$$,'withdraw accepted');
SELECT lives_ok($$SELECT public.admin_withdraw_broadcast(pg_temp.op(4),(SELECT id FROM ids WHERE name='all'))$$,'withdraw retry is idempotent');
SELECT is(jsonb_array_length(public.admin_broadcast_register()),5,'register lists every broadcast');
RESET ROLE;
SELECT private.deliver_broadcasts(100);
SELECT is((SELECT state FROM private.broadcast_deliveries WHERE broadcast_id=(SELECT id FROM ids WHERE name='all')),'withdrawn','withdrawal finished');
SELECT is((SELECT count(*)::INT FROM public.notifications WHERE subject_id=(SELECT id FROM ids WHERE name='all')),0,'withdrawn broadcast left every inbox');
SELECT is(pg_temp.inbox(3),1,'other broadcasts stay');
SELECT is((SELECT count(*)::INT FROM public.audit_log WHERE target_id=(SELECT id FROM ids WHERE name='all')),2,'publish and withdraw are audited');

SELECT * FROM finish();
ROLLBACK;
