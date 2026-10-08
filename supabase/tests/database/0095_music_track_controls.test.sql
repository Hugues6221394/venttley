-- A track can be taken down and put back by an admin with MFA, with a reason,
-- once per operation, and members stop seeing it the moment it is down.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
SELECT ('3a5c0000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'mus'||n,'x','x','Mus '||n,'mus '||n,'mus'||n,r::public.user_role_type,'active',1990
FROM (VALUES(1,'admin'),(2,'moderator'))t(n,r);
INSERT INTO auth.users(id,aud,role,created_at,updated_at)
SELECT user_id,'authenticated','authenticated',now(),now() FROM public.users WHERE anonymous_pseudonym LIKE 'mus%';
INSERT INTO auth.sessions(id,user_id,created_at,updated_at,aal)
SELECT user_id,user_id,now(),now(),'aal2' FROM public.users WHERE anonymous_pseudonym LIKE 'mus%';
SET session_replication_role=origin;
CREATE FUNCTION pg_temp.id(n INT) RETURNS UUID LANGUAGE sql AS $$SELECT ('3a5c0000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID$$;
CREATE FUNCTION pg_temp.as_user(n INT,aal TEXT DEFAULT 'aal2') RETURNS VOID LANGUAGE sql AS $$
 SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.id(n),'session_id',pg_temp.id(n),'role','authenticated','aal',aal)::TEXT,true)::TEXT;
$$;
INSERT INTO public.music_tracks(track_id,provider,provider_track_id,title,artist,preview_url,duration_ms,mood_tags,license_code,license_url,rights_holder,allowed_regions,is_active,cache_allowed)
VALUES('3a5c0000-0000-4000-8000-0000000000aa','royalty_free','t1','Quiet','Someone','https://example.com/p.mp3',30000,'{}','CC0','https://example.com/l','Someone','{}',true,false);
CREATE FUNCTION pg_temp.track() RETURNS public.music_tracks LANGUAGE sql AS $$SELECT * FROM public.music_tracks WHERE track_id='3a5c0000-0000-4000-8000-0000000000aa'$$;
GRANT EXECUTE ON FUNCTION pg_temp.track() TO authenticated;

SELECT ok(NOT has_function_privilege('anon','public.admin_set_music_track(uuid,uuid,boolean,timestamptz,text)','EXECUTE'),'anonymous cannot change tracks');

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(2);
SELECT throws_like($$SELECT public.admin_set_music_track('3a5c0000-0000-4000-8000-0000000000f1','3a5c0000-0000-4000-8000-0000000000aa',false,NULL,'rights claim')$$,'%not_authorized%','moderators cannot take tracks down');
SELECT pg_temp.as_user(1,'aal1');
SELECT throws_like($$SELECT public.admin_set_music_track('3a5c0000-0000-4000-8000-0000000000f1','3a5c0000-0000-4000-8000-0000000000aa',false,NULL,'rights claim')$$,'%aal2%','taking a track down requires MFA');
SELECT pg_temp.as_user(1);
SELECT throws_like($$SELECT public.admin_set_music_track('3a5c0000-0000-4000-8000-0000000000f1','3a5c0000-0000-4000-8000-0000000000aa',false,NULL,'x')$$,'%invalid_input%','a reason is required');
SELECT throws_like($$SELECT public.admin_set_music_track('3a5c0000-0000-4000-8000-0000000000f1','3a5c0000-0000-4000-8000-0000000000aa',true,NULL,'no change')$$,'%no_change%','a save that changes nothing is refused');
SELECT throws_like($$SELECT public.admin_set_music_track('3a5c0000-0000-4000-8000-0000000000f1','3a5c0000-0000-4000-8000-0000000000aa',true,now()-interval '1 day','renewal')$$,'%rights_expired%','an active track cannot carry expired rights');
SELECT lives_ok($$SELECT public.admin_set_music_track('3a5c0000-0000-4000-8000-0000000000f1','3a5c0000-0000-4000-8000-0000000000aa',false,NULL,'rights claim')$$,'admin takes the track down');
SELECT lives_ok($$SELECT public.admin_set_music_track('3a5c0000-0000-4000-8000-0000000000f1','3a5c0000-0000-4000-8000-0000000000aa',false,NULL,'rights claim')$$,'retrying the same operation is harmless');
RESET ROLE;
SELECT is((pg_temp.track()).is_active,false,'the track is down');
SELECT is((SELECT count(*)::INT FROM public.audit_log WHERE action='music.track_taken_down' AND target_id='3a5c0000-0000-4000-8000-0000000000aa'),1,'audited once');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(1);
SELECT lives_ok($$SELECT public.admin_set_music_track('3a5c0000-0000-4000-8000-0000000000f2','3a5c0000-0000-4000-8000-0000000000aa',true,now()+interval '90 days','claim withdrawn')$$,'admin restores it with a new expiry');
RESET ROLE;
SELECT ok((pg_temp.track()).is_active AND (pg_temp.track()).rights_expires_at > now()+interval '89 days','restored with the new rights date');
SELECT is((SELECT count(*)::INT FROM public.audit_log WHERE action='music.track_restored' AND target_id='3a5c0000-0000-4000-8000-0000000000aa'),1,'restore audited');

SELECT * FROM finish();
ROLLBACK;
