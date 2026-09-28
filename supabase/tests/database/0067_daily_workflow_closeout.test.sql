BEGIN;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO auth.users(id) VALUES('1a670000-0000-4000-8000-000000000001'),('1a670000-0000-4000-8000-000000000002');
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,user_role,account_status,birth_year,display_name,display_name_normalized,username_normalized)
VALUES('1a670000-0000-4000-8000-000000000001','closetest','x','x','super_admin','active',1990,'Close Test','close test','closetest'),
('1a670000-0000-4000-8000-000000000002','closemember','x','x','normal','active',1990,'Close Member','close member','closemember');
INSERT INTO public.moderation_cases(case_id,target_type,target_id,subject_id,assignee_id,sla_due_at,updated_at)
SELECT ('1a670000-1000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'post',gen_random_uuid(),'1a670000-0000-4000-8000-000000000002',
'1a670000-0000-4000-8000-000000000001','1900-01-01','2000-01-01' FROM generate_series(1,240)i;
INSERT INTO public.moderation_appeals(appeal_id,case_id,appellant_id,statement,created_at)
SELECT ('1a670000-2000-4000-8000-'||lpad(i::text,12,'0'))::uuid,('1a670000-1000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
'1a670000-0000-4000-8000-000000000002','Synthetic appeal','1800-01-01' FROM generate_series(1,240)i;
INSERT INTO public.posts(post_id,author_id,category_name,content,post_mood,crisis_level,created_at)
SELECT ('1a670000-3000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'1a670000-0000-4000-8000-000000000002','mental_health','Synthetic signal','sad','high','1800-01-01' FROM generate_series(1,240)i;
INSERT INTO private.support_cases(support_case_id,source_kind,category,sla_due_at,created_by)
VALUES('1a670000-4000-4000-8000-000000000001','other','technical',now(),'1a670000-0000-4000-8000-000000000001');
INSERT INTO private.support_case_events(event_id,support_case_id,event_kind,actor_id,detail,created_at)
SELECT ('1a670000-5000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'1a670000-4000-4000-8000-000000000001','status_changed','1a670000-0000-4000-8000-000000000001',
'{"from":"open","to":"waiting_internal","private_body":"never_return","priority":"high","assigned":true}','2000-01-01' FROM generate_series(1,40)i;
SET session_replication_role=origin;
SELECT ok(NOT has_function_privilege('anon','public.admin_case_work_queue(text,uuid,int,jsonb)','EXECUTE'),'anonymous queue denied');
SELECT ok(NOT has_function_privilege('anon','public.admin_support_history(uuid,timestamptz,uuid,int)','EXECUTE'),'anonymous history denied');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a670000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
SELECT is((SELECT count(*)::int FROM public.admin_case_work_queue('unresolved','1a670000-0000-4000-8000-000000000001',31)),31,'bounded case page');
SELECT ok((SELECT NOT (to_jsonb(q)?'evidence') FROM public.admin_case_work_queue(NULL,NULL,1)q),'case queue does not serialize evidence');
SELECT is((SELECT case_id::text FROM public.admin_case_work_queue('unresolved','1a670000-0000-4000-8000-000000000001',1,'{"a":0,"b":0,"t":"1900-01-01","k":"","i":"1a670000-1000-4000-8000-000000000230"}')),'1a670000-1000-4000-8000-000000000231','case cursor reaches beyond old 200-row cap');
SELECT is((SELECT appeal_id::text FROM public.admin_appeal_work_queue('open',1,'{"a":0,"b":0,"t":"1800-01-01","k":"","i":"1a670000-2000-4000-8000-000000000230"}')),'1a670000-2000-4000-8000-000000000231','appeal cursor tie-break reaches deep page');
SELECT is((SELECT ref_id::text FROM public.admin_safety_work_queue(false,1,'{"a":0,"b":-3,"t":"1800-01-01","k":"crisis_post","i":"1a670000-3000-4000-8000-000000000230"}')),'1a670000-3000-4000-8000-000000000231','safety cursor reaches deep page');
SELECT throws_like($$SELECT * FROM public.admin_case_work_queue(NULL,NULL,500)$$,'%invalid_queue%','page cap enforced');
SELECT throws_like($$SELECT * FROM public.admin_appeal_work_queue('bogus')$$,'%invalid_queue%','filter validation');
SELECT throws_like($$SELECT * FROM public.admin_safety_work_queue(false,2,'{}')$$,'%invalid_cursor%','malformed cursor rejected');
SELECT is((SELECT count(*)::int FROM public.admin_support_history('1a670000-4000-4000-8000-000000000001')),31,'history bounded');
SELECT is((SELECT event_id::text FROM public.admin_support_history('1a670000-4000-4000-8000-000000000001','2000-01-01','1a670000-5000-4000-8000-000000000020',1)),'1a670000-5000-4000-8000-000000000019','history tie-break');
SELECT ok((SELECT bool_and(to_jsonb(e)::text NOT LIKE '%never_return%') FROM public.admin_support_history('1a670000-4000-4000-8000-000000000001')e),'history excludes arbitrary detail');
SELECT throws_like($$SELECT * FROM public.admin_support_bindings('member','close')$$,'%aal2_required%','member lookup requires MFA');
SELECT throws_like($$SELECT public.admin_case_command(gen_random_uuid(),'1a670000-1000-4000-8000-000000000001','2000-01-01','decision','no_action','Synthetic')$$,'%aal2_required%','case command requires MFA');
SELECT throws_like($$SELECT public.admin_safety_command(gen_random_uuid(),'post','1a670000-3000-4000-8000-000000000001','Synthetic')$$,'%aal2_required%','safety command requires MFA');
SELECT set_config('request.jwt.claims','{"sub":"1a670000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT is((SELECT count(*)::int FROM public.admin_support_bindings('member','closemember')),1,'scoped username lookup');
SELECT is((SELECT count(*)::int FROM public.admin_support_bindings('member','%%%%')),0,'search wildcard literal');
SELECT throws_like($$SELECT * FROM public.admin_support_bindings('member','@@@@')$$,'%invalid_query%','prefix normalization cannot turn repeated at signs into a bulk lookup');
SELECT throws_like($$SELECT public.admin_create_support_case_bound(gen_random_uuid(),'appeal','1a670000-2000-4000-8000-000000000001','1a670000-0000-4000-8000-000000000001','appeal_help','normal')$$,'%source_member_mismatch%','cannot bind unrelated member to source');
SELECT throws_ok($$SELECT public.admin_case_command(gen_random_uuid(),'1a670000-1000-4000-8000-000000000001','1999-01-01','decision','no_action','Synthetic')$$,'PT409','workflow_conflict','stale case cannot mutate');
SELECT lives_ok($$SELECT public.admin_case_command('1a670000-6000-4000-8000-000000000001','1a670000-1000-4000-8000-000000000001','2000-01-01','decision','no_action','Synthetic')$$,'canonical case decision');
SELECT lives_ok($$SELECT public.admin_case_command('1a670000-6000-4000-8000-000000000001','1a670000-1000-4000-8000-000000000001','2000-01-01','decision','no_action','Synthetic')$$,'exact case retry');
SELECT throws_like($$SELECT public.admin_case_command('1a670000-6000-4000-8000-000000000001','1a670000-1000-4000-8000-000000000001','2000-01-01','decision','no_action','Changed')$$,'%idempotency_payload_mismatch%','case changed retry denied');
SELECT throws_like($$SELECT public.admin_appeal_command(gen_random_uuid(),'1a670000-2000-4000-8000-000000000001','upheld','Synthetic')$$,'%someone else%','original decider cannot review appeal');
SELECT lives_ok($$SELECT public.admin_appeal_command('1a670000-6000-4000-8000-000000000002','1a670000-2000-4000-8000-000000000002','upheld','Synthetic')$$,'independent appeal decision');
SELECT lives_ok($$SELECT public.admin_appeal_command('1a670000-6000-4000-8000-000000000002','1a670000-2000-4000-8000-000000000002','upheld','Synthetic')$$,'exact appeal retry');
SELECT lives_ok($$SELECT public.admin_safety_command('1a670000-6000-4000-8000-000000000003','post','1a670000-3000-4000-8000-000000000001','Synthetic')$$,'canonical safety review');
SELECT lives_ok($$SELECT public.admin_safety_command('1a670000-6000-4000-8000-000000000003','post','1a670000-3000-4000-8000-000000000001','Synthetic')$$,'exact safety retry');
SELECT throws_ok($$SELECT public.admin_safety_command(gen_random_uuid(),'post','1a670000-3000-4000-8000-000000000001','Synthetic')$$,'PT409','workflow_conflict','new operation cannot review already cleared signal');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.moderation_case_events WHERE case_id='1a670000-1000-4000-8000-000000000001' AND kind='decided'),1,'case retry records one decision');
UPDATE public.users SET account_status='suspended' WHERE user_id='1a670000-0000-4000-8000-000000000001';
SET LOCAL ROLE authenticated;
SELECT throws_like($$SELECT * FROM public.admin_support_history('1a670000-4000-4000-8000-000000000001')$$,'%not_authorized%','suspended history denied');
SELECT throws_like($$SELECT public.admin_case_command('1a670000-6000-4000-8000-000000000001','1a670000-1000-4000-8000-000000000001','2000-01-01','decision','no_action','Synthetic')$$,'%not_authorized%','suspended receipt replay denied');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
