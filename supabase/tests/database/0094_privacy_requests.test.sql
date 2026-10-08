-- Privacy requests: they open themselves, move through a checked workflow,
-- export a member's own data without secrets, email it only to a verified
-- address, and close themselves when the account is erased.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year,recovery_email,recovery_email_verified)
SELECT ('9e1a0000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'priv'||n,'x','secret-recovery-hash','Priv '||n,'priv '||n,'priv'||n,r::public.user_role_type,'active',1990,
       CASE WHEN n=3 THEN 'priv3@example.com' END, n=3
FROM (VALUES(1,'admin'),(2,'support'),(3,'normal'),(4,'normal'))t(n,r);
INSERT INTO auth.users(id,aud,role,created_at,updated_at)
SELECT user_id,'authenticated','authenticated',now(),now() FROM public.users WHERE anonymous_pseudonym LIKE 'priv%';
INSERT INTO auth.sessions(id,user_id,created_at,updated_at,aal)
SELECT user_id,user_id,now(),now(),'aal2' FROM public.users WHERE anonymous_pseudonym LIKE 'priv%';
SET session_replication_role=origin;
CREATE FUNCTION pg_temp.id(n INT) RETURNS UUID LANGUAGE sql AS $$SELECT ('9e1a0000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID$$;
CREATE FUNCTION pg_temp.op(n INT) RETURNS UUID LANGUAGE sql AS $$SELECT ('9e1a0000-1000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID$$;
CREATE FUNCTION pg_temp.as_user(n INT,aal TEXT DEFAULT 'aal2') RETURNS VOID LANGUAGE sql AS $$
 SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.id(n),'session_id',pg_temp.id(n),'role','authenticated','aal',aal)::TEXT,true)::TEXT;
$$;
CREATE FUNCTION pg_temp.req(n INT,k TEXT) RETURNS private.privacy_requests LANGUAGE sql AS $$
 SELECT * FROM private.privacy_requests WHERE member_id=pg_temp.id(n) AND kind=k ORDER BY created_at DESC LIMIT 1$$;

SELECT ok(NOT has_table_privilege('authenticated','private.privacy_requests','SELECT'),'clients cannot read privacy requests');
SELECT ok(NOT has_function_privilege('anon','public.admin_privacy_export(uuid)','EXECUTE'),'anonymous cannot export');
SELECT is((SELECT public FROM storage.buckets WHERE id='privacy-exports'),false,'the export bucket is private');

-- Intake.
UPDATE public.users SET deletion_requested_at=now() WHERE user_id=pg_temp.id(4);
SELECT is((pg_temp.req(4,'deletion')).state,'received','asking to delete opens a deletion request');
SELECT ok((pg_temp.req(4,'deletion')).due_at > now()+interval '29 days','due in 30 days');
UPDATE public.users SET deletion_requested_at=NULL WHERE user_id=pg_temp.id(4);
SELECT is((pg_temp.req(4,'deletion')).state,'withdrawn','cancelling the deletion withdraws it');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(3);
SELECT public.member_start_support(pg_temp.op(9),'privacy_request','My data please','Please send me a copy of my data.');
RESET ROLE;
SELECT is((pg_temp.req(3,'other')).source,'support','a privacy support conversation opens a request');

-- Staff.
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(2);
SELECT throws_like($$SELECT public.admin_privacy_requests()$$,'%not_authorized%','support staff cannot read privacy requests');
SELECT pg_temp.as_user(1,'aal1');
SELECT throws_like($$SELECT public.admin_open_privacy_request(pg_temp.op(1),pg_temp.id(3),'access','Asked by email from the address on file')$$,'%aal2%','opening requires MFA');
SELECT pg_temp.as_user(1);
SELECT is(jsonb_array_length(public.admin_privacy_requests('open')),1,'one open request in the queue');
SELECT throws_like($$SELECT public.admin_open_privacy_request(pg_temp.op(1),pg_temp.id(3),'access','x')$$,'%invalid_input%','identity note required');
SELECT lives_ok($$SELECT public.admin_open_privacy_request(pg_temp.op(1),pg_temp.id(3),'access','Asked by email from the address on file')$$,'staff open an access request');
SELECT throws_like($$SELECT public.admin_open_privacy_request(pg_temp.op(2),pg_temp.id(3),'access','Again')$$,'%privacy_request_open%','only one open request per kind');
RESET ROLE;
CREATE TEMP TABLE r AS SELECT request_id, version FROM private.privacy_requests WHERE member_id=pg_temp.id(3) AND kind='access';
GRANT SELECT ON r TO authenticated;
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(1);
SELECT lives_ok($$SELECT public.admin_privacy_request_command(pg_temp.op(3),(SELECT request_id FROM r),(SELECT version FROM r),'start')$$,'start the request');
SELECT throws_like($$SELECT public.admin_privacy_request_command(pg_temp.op(4),(SELECT request_id FROM r),(SELECT version FROM r),'start')$$,'%privacy_conflict%','a stale version is refused');
SELECT is(public.admin_privacy_export((SELECT request_id FROM r))->'account'->>'anonymous_pseudonym','priv3','the export carries the account');
SELECT ok(NOT (public.admin_privacy_export((SELECT request_id FROM r))->'account' ? 'recovery_key_hash'),'secrets never leave');
SELECT ok(public.admin_privacy_export((SELECT request_id FROM r))->'data' ? 'support_conversations','support conversations are included');
SELECT throws_like($$SELECT public.admin_privacy_request_command(pg_temp.op(5),(SELECT request_id FROM r),2,'record_export',NULL,'../etc/passwd','https://x')$$,'%invalid_input%','an export path outside the request is refused');
SELECT lives_ok(format($$SELECT public.admin_privacy_request_command(pg_temp.op(5),(SELECT request_id FROM r),2,'record_export',NULL,%L,'https://example.supabase.co/signed')$$,
  (SELECT request_id FROM r)::TEXT||'/0b0b0b0b-0000-4000-8000-000000000001.json'),'export link recorded and emailed');
RESET ROLE;
SELECT is((SELECT to_address FROM public.email_outbox WHERE user_id=pg_temp.id(3) ORDER BY created_at DESC LIMIT 1),'priv3@example.com','sent to the verified address');
SELECT ok((SELECT export_expires_at FROM private.privacy_requests WHERE request_id=(SELECT request_id FROM r)) > now()+interval '6 days','link lasts a week');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(1);
SELECT throws_like($$SELECT public.admin_privacy_request_command(pg_temp.op(6),(SELECT request_id FROM r),3,'complete','x')$$,'%invalid_input%','completing needs an outcome note');
SELECT lives_ok($$SELECT public.admin_privacy_request_command(pg_temp.op(6),(SELECT request_id FROM r),3,'complete','Export sent by email.')$$,'complete the request');
SELECT lives_ok($$SELECT public.admin_privacy_request_command(pg_temp.op(6),(SELECT request_id FROM r),3,'complete','Export sent by email.')$$,'retry is idempotent');
SELECT ok((SELECT bool_and(k IN (SELECT e->>'kind' FROM jsonb_array_elements(q->'events') e))
             FROM jsonb_array_elements(public.admin_privacy_member_requests(pg_temp.id(3))->'requests') q, unnest(ARRAY['opened','started','export_sent','completed']) k
            WHERE q->>'kind'='access'),'history is kept');
RESET ROLE;
SELECT is((SELECT state FROM private.privacy_requests WHERE request_id=(SELECT request_id FROM r)),'completed','request completed');
SELECT throws_like($$UPDATE private.privacy_request_events SET note='x'$$,'%immutable%','history cannot be edited');

-- Erasure closes what is left.
UPDATE public.users SET deletion_requested_at=now() WHERE user_id=pg_temp.id(4);
CREATE TEMP TABLE d AS SELECT request_id FROM private.privacy_requests WHERE member_id=pg_temp.id(4) AND state='received';
GRANT SELECT ON d TO authenticated;
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(1);
SELECT throws_like($$SELECT public.admin_privacy_request_command(pg_temp.op(7),(SELECT request_id FROM d),1,'complete','done')$$,'%deletion_completes_itself%','staff cannot mark an erasure done');
RESET ROLE;
DELETE FROM auth.users WHERE id=pg_temp.id(4);
SELECT is((SELECT state FROM private.privacy_requests WHERE request_id=(SELECT request_id FROM d)),'completed','erasing the account completes the deletion request');
SELECT is((SELECT member_pseudonym FROM private.privacy_requests WHERE request_id=(SELECT request_id FROM d)),'priv4','the record keeps who asked');

SELECT * FROM finish();
ROLLBACK;
