-- Only a super admin can read the release switches, and the read-out matches them.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
SELECT ('5c0e0000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'ctl'||n,'x','x','Ctl '||n,'ctl '||n,'ctl'||n,r::public.user_role_type,'active',1990
FROM (VALUES(1,'super_admin'),(2,'admin'))t(n,r);
SET session_replication_role=origin;
CREATE FUNCTION pg_temp.as_user(n INT) RETURNS VOID LANGUAGE sql AS $$
 SELECT set_config('request.jwt.claims',jsonb_build_object('sub',('5c0e0000-0000-4000-8000-'||lpad(n::TEXT,12,'0')),'role','authenticated')::TEXT,true)::TEXT;
$$;

SELECT ok(NOT has_function_privilege('anon','public.admin_control_switches()','EXECUTE'),'anonymous cannot read switches');
SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(2);
SELECT throws_like($$SELECT public.admin_control_switches()$$,'%not_authorized%','admins cannot read switches');
SELECT pg_temp.as_user(1);
CREATE TEMP TABLE r AS SELECT public.admin_control_switches() AS j;
RESET ROLE;
SELECT is(((SELECT j FROM r)->'staff_inbox'->>'enabled')::BOOLEAN,(SELECT enabled FROM private.staff_inbox_control LIMIT 1),'inbox state matches');
SELECT is(((SELECT j FROM r)->>'access_reviews')::BOOLEAN,(SELECT enabled FROM private.access_review_control LIMIT 1),'access review state matches');
SELECT is(((SELECT j FROM r)->>'broadcast_approvals')::BOOLEAN,(SELECT enabled FROM private.broadcast_approval_control LIMIT 1),'broadcast approval state matches');
SELECT ok(((SELECT j FROM r)->>'active_super_admins')::INT >= 1,'counts active super admins');

SELECT * FROM finish();
ROLLBACK;
