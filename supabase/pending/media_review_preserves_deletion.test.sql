-- PREPARED, NOT RUN. Disposable DB only, paired security draft required.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
SELECT ('3b792000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'mediareview'||n,'x','x','Media Review','media review','mediareview'||n,r::public.user_role_type,'active',1990
FROM (VALUES(1,'super_admin'),(2,'admin'),(3,'moderator'),(4,'support'),(5,'analyst'),(6,'read_only_auditor'))t(n,r);
INSERT INTO auth.users(id,aud,role,created_at,updated_at)
SELECT user_id,'authenticated','authenticated',now(),now() FROM public.users WHERE anonymous_pseudonym LIKE 'mediareview%';
INSERT INTO auth.sessions(id,user_id,created_at,updated_at,aal)
SELECT user_id,user_id,now(),now(),'aal2' FROM public.users WHERE anonymous_pseudonym LIKE 'mediareview%';
INSERT INTO public.posts(post_id,author_id,category_name,content,post_mood,deleted_at,media_status)
VALUES('3b792000-1000-4000-8000-000000000001','3b792000-0000-4000-8000-000000000001','vent_zone','Synthetic removed content','angry',now(),'blocked'),
('3b792000-1000-4000-8000-000000000002','3b792000-0000-4000-8000-000000000001','vent_zone','Synthetic visible content','angry',NULL,'sensitive');
INSERT INTO public.whispers(whisper_id,author_id,audio_path,audio_url,audio_duration_seconds,category_name,deleted_at,media_status)
VALUES('3b792000-2000-4000-8000-000000000001','3b792000-0000-4000-8000-000000000001','synthetic/audio.m4a','https://media.invalid/synthetic.m4a',12,'confessions',now(),'blocked');
SET session_replication_role=origin;
CREATE FUNCTION pg_temp.claim(n INT,aal TEXT DEFAULT 'aal2') RETURNS VOID LANGUAGE sql AS $$
 SELECT set_config('request.jwt.claims',jsonb_build_object('sub','3b792000-0000-4000-8000-'||lpad(n::TEXT,12,'0'),'session_id','3b792000-0000-4000-8000-'||lpad(n::TEXT,12,'0'),'role','authenticated','aal',aal)::TEXT,true)::TEXT;
$$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(1,'aal1');
SELECT throws_like($$SELECT public.admin_set_media_status('post','3b792000-1000-4000-8000-000000000002','clean')$$,'%aal2_required%','MFA required');
SELECT pg_temp.claim(1);
SELECT throws_like($$SELECT public.admin_set_media_status('post','3b792000-1000-4000-8000-000000000001','clean')$$,'%content_deleted_use_restore_workflow%','image approval does not undelete a Vent');
SELECT throws_like($$SELECT public.admin_set_media_status('whisper','3b792000-2000-4000-8000-000000000001','clean')$$,'%content_deleted_use_restore_workflow%','image approval does not undelete a Whisper');
SELECT lives_ok($$SELECT public.admin_set_media_status('post','3b792000-1000-4000-8000-000000000002','clean','Synthetic review')$$,'eligible classification changes');
SELECT lives_ok($$SELECT public.admin_set_media_status('post','3b792000-1000-4000-8000-000000000002','clean','Synthetic review')$$,'same-state retry');
SELECT pg_temp.claim(2);
SELECT lives_ok($$SELECT public.admin_set_media_status('post','3b792000-1000-4000-8000-000000000002','clean')$$,'admin permitted');
SELECT pg_temp.claim(3);
SELECT lives_ok($$SELECT public.admin_set_media_status('post','3b792000-1000-4000-8000-000000000002','clean')$$,'moderator permitted');
SELECT pg_temp.claim(4);
SELECT throws_like($$SELECT public.admin_set_media_status('post','3b792000-1000-4000-8000-000000000002','clean')$$,'%not_authorized%','support refused');
SELECT pg_temp.claim(5);
SELECT throws_like($$SELECT public.admin_set_media_status('post','3b792000-1000-4000-8000-000000000002','clean')$$,'%not_authorized%','analyst refused');
SELECT pg_temp.claim(6);
SELECT throws_like($$SELECT public.admin_set_media_status('post','3b792000-1000-4000-8000-000000000002','clean')$$,'%not_authorized%','auditor refused');
RESET ROLE;
SELECT is((SELECT count(*)::INT FROM public.audit_log WHERE action='media.set_status' AND target_id='3b792000-1000-4000-8000-000000000002'),1,'retry creates no duplicate audit transition');
SELECT ok((SELECT deleted_at IS NOT NULL FROM public.posts WHERE post_id='3b792000-1000-4000-8000-000000000001'),'Vent deletion preserved');
SELECT ok((SELECT deleted_at IS NOT NULL FROM public.whispers WHERE whisper_id='3b792000-2000-4000-8000-000000000001'),'Whisper deletion preserved');
DELETE FROM auth.sessions WHERE user_id='3b792000-0000-4000-8000-000000000001';
SET LOCAL ROLE authenticated;
SELECT pg_temp.claim(1);
SELECT throws_like($$SELECT public.admin_set_media_status('post','3b792000-1000-4000-8000-000000000002','blocked')$$,'%session_unavailable%','deleted session cannot classify media');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
