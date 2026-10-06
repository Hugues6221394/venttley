-- Who a moderation case can be handed to: moderation staff only, active only,
-- and only moderation staff may ask.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SET session_replication_role=replica;
INSERT INTO auth.users(id)
SELECT ('1c0a5000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID FROM generate_series(1,6) n;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year)
SELECT ('1c0a5000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'casepick'||n,'x','x','Casepick '||n,'casepick '||n,'casepick'||n,r::public.user_role_type,s,1990
FROM (VALUES(1,'super_admin','active'),(2,'admin','active'),(3,'moderator','active'),(4,'moderator','suspended'),(5,'support','active'),(6,'normal','active'))t(n,r,s);
SET session_replication_role=origin;
CREATE FUNCTION pg_temp.as_user(n INT) RETURNS VOID LANGUAGE sql AS $$
 SELECT set_config('request.jwt.claims',jsonb_build_object('sub',('1c0a5000-0000-4000-8000-'||lpad(n::TEXT,12,'0')),'role','authenticated')::TEXT,true)::TEXT;
$$;

SELECT ok(NOT has_function_privilege('anon','public.admin_case_assignees(text)','EXECUTE'),'anonymous lookup denied');

SET LOCAL ROLE authenticated;
SELECT pg_temp.as_user(3);
SELECT set_eq($$SELECT username FROM public.admin_case_assignees('Casepick')$$,
  ARRAY['casepick1','casepick2','casepick3'],'active moderation staff only; suspended, support and members excluded');
SELECT is((SELECT count(*)::int FROM public.admin_case_assignees('%')),0,'wildcard is literal');
SELECT throws_like($$SELECT * FROM public.admin_case_assignees(repeat('x',51))$$,'%invalid_query%','oversized search rejected');
SELECT throws_like($$SELECT * FROM public.admin_case_assignees(NULL)$$,'%invalid_query%','null search rejected');
SELECT pg_temp.as_user(5);
SELECT throws_like($$SELECT * FROM public.admin_case_assignees('')$$,'%not_authorized%','support cannot list case assignees');
SELECT pg_temp.as_user(6);
SELECT throws_like($$SELECT * FROM public.admin_case_assignees('')$$,'%not_authorized%','members cannot list case assignees');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
