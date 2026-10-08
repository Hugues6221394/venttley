-- Resend and revoke are recorded only for unfinished invitations, by a super
-- admin with MFA, and revoke only once staff access is gone.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
SELECT ('1a7e0000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'invt'||n,'x','x','Invt '||n,'invt '||n,'invt'||n,r::public.user_role_type,'active',1990
FROM (VALUES(1,'super_admin'),(2,'admin'),(3,'moderator'),(4,'support'))t(n,r);
INSERT INTO auth.users(id,aud,role,created_at,updated_at,raw_app_meta_data)
SELECT user_id,'authenticated','authenticated',now(),now(),
       CASE WHEN anonymous_pseudonym='invt3' THEN '{"staff_invite_pending":true}'::JSONB ELSE '{}'::JSONB END
FROM public.users WHERE anonymous_pseudonym LIKE 'invt%';
INSERT INTO auth.sessions(id,user_id,created_at,updated_at,aal)
SELECT user_id,user_id,now(),now(),'aal2' FROM public.users WHERE anonymous_pseudonym LIKE 'invt%';
SET session_replication_role=origin;
CREATE FUNCTION pg_temp.id(n INT) RETURNS UUID LANGUAGE sql AS $$SELECT ('1a7e0000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID$$;
CREATE FUNCTION pg_temp.as_user(n INT,aal TEXT DEFAULT 'aal2') RETURNS VOID LANGUAGE sql AS $$
 SELECT set_config('request.jwt.claims',jsonb_build_object('sub',pg_temp.id(n),'session_id',pg_temp.id(n),'role','authenticated','aal',aal)::TEXT,true)::TEXT;
$$;

SELECT ok(NOT has_function_privilege('anon','public.admin_note_staff_invitation(uuid,text,text)','EXECUTE'),'anonymous cannot record invitation actions');

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(2);
SELECT throws_like($$SELECT public.admin_note_staff_invitation(pg_temp.id(3),'resent','spam folder')$$,'%not_authorized%','admins cannot resend');
SELECT pg_temp.as_user(1,'aal1');
SELECT throws_like($$SELECT public.admin_note_staff_invitation(pg_temp.id(3),'resent','spam folder')$$,'%aal2%','resend requires MFA');
SELECT pg_temp.as_user(1);
SELECT throws_like($$SELECT public.admin_note_staff_invitation(pg_temp.id(4),'resent','spam folder')$$,'%invitation_not_pending%','a finished setup cannot be resent');
SELECT throws_like($$SELECT public.admin_note_staff_invitation(pg_temp.id(3),'deleted','spam folder')$$,'%invalid_input%','unknown action refused');
SELECT throws_like($$SELECT public.admin_note_staff_invitation(pg_temp.id(3),'resent','x')$$,'%invalid_input%','a reason is required');
SELECT lives_ok($$SELECT public.admin_note_staff_invitation(pg_temp.id(3),'resent','spam folder')$$,'pending invitation can be resent');
SELECT throws_like($$SELECT public.admin_note_staff_invitation(pg_temp.id(3),'revoked','wrong address')$$,'%invitation_access_exists%','revoke is refused while staff access remains');
RESET ROLE;
UPDATE public.users SET user_role='normal' WHERE user_id=pg_temp.id(3);
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(1);
SELECT throws_like($$SELECT public.admin_note_staff_invitation(pg_temp.id(3),'resent','spam folder')$$,'%invitation_not_pending%','no resend once access is removed');
SELECT lives_ok($$SELECT public.admin_note_staff_invitation(pg_temp.id(3),'revoked','wrong address')$$,'revoke recorded after access is removed');
RESET ROLE;
SELECT is((SELECT count(*)::INT FROM public.audit_log WHERE target_id=pg_temp.id(3) AND action IN ('staff_invitation_resent','staff_invitation_revoked')),2,'both actions are audited');

SELECT * FROM finish();
ROLLBACK;
