-- Staff RLS policy matrix.
--
-- The README asks for this per table across "anonymous, normal, suspended
-- staff, each staff role, super admin, and service role". Writing the
-- suspended-staff row is what found 20261018090000: there was nothing to
-- assert, because suspension had no effect on staff authorisation anywhere.
--
-- These assertions act as the real database roles — SET LOCAL ROLE
-- authenticated with a JWT claim — rather than checking predicates as
-- postgres. As postgres, RLS is bypassed and every one of these would pass
-- while proving nothing. That is the same class of mistake as a policy with
-- no grant behind it: the check appears to run and never does.
--
-- audit_log carries the matrix because its confidentiality rests on exactly
-- one policy expression, with a SELECT grant to `authenticated` that cannot
-- be removed — staff are authenticated users too. There is no second layer
-- behind it.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(21);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, deactivated_at, birth_year)
VALUES
  ('eee10000-0000-4000-8000-000000000001','mxsuper','mxsuper','x','mxsuper','mxsuper','mxsuper','super_admin','active',NULL,1990),
  ('eee10000-0000-4000-8000-000000000002','mxadmin','mxadmin','x','mxadmin','mxadmin','mxadmin','admin','active',NULL,1990),
  ('eee10000-0000-4000-8000-000000000003','mxmod','mxmod','x','mxmod','mxmod','mxmod','moderator','active',NULL,1990),
  ('eee10000-0000-4000-8000-000000000004','mxsupport','mxsupport','x','mxsupport','mxsupport','mxsupport','support','active',NULL,1990),
  ('eee10000-0000-4000-8000-000000000005','mxanalyst','mxanalyst','x','mxanalyst','mxanalyst','mxanalyst','analyst','active',NULL,1990),
  ('eee10000-0000-4000-8000-000000000006','mxauditor','mxauditor','x','mxauditor','mxauditor','mxauditor','read_only_auditor','active',NULL,1990),
  ('eee10000-0000-4000-8000-000000000007','mxmember','mxmember','x','mxmember','mxmember','mxmember','normal','active',NULL,1995),
  -- The rows that had nothing to assert before 20261018090000.
  ('eee10000-0000-4000-8000-000000000008','mxmodsusp','mxmodsusp','x','mxmodsusp','mxmodsusp','mxmodsusp','moderator','suspended',NULL,1990),
  ('eee10000-0000-4000-8000-000000000009','mxadminsusp','mxadminsusp','x','mxadminsusp','mxadminsusp','mxadminsusp','admin','suspended',NULL,1990),
  ('eee10000-0000-4000-8000-00000000000a','mxsuperdeact','mxsuperdeact','x','mxsuperdeact','mxsuperdeact','mxsuperdeact','super_admin','active',now(),1990),
  ('eee10000-0000-4000-8000-00000000000b','mxadminrestr','mxadminrestr','x','mxadminrestr','mxadminrestr','mxadminrestr','admin','restricted',NULL,1990);

INSERT INTO public.audit_log (actor_id, actor_pseudonym, actor_role, action, target_type)
VALUES ('eee10000-0000-4000-8000-000000000001','mxsuper','super_admin','matrix.probe','user');

INSERT INTO public.analytics_events (name) VALUES ('matrix.probe');

SET session_replication_role = origin;

-- ---------------------------------------------------------------------------
-- The predicate itself. Sixty-five functions ask it who counts as staff.
-- ---------------------------------------------------------------------------

SELECT ok(
  public.is_staff('eee10000-0000-4000-8000-000000000002', ARRAY['admin']),
  'an active admin is staff'
);
SELECT ok(
  NOT public.is_staff('eee10000-0000-4000-8000-000000000009', ARRAY['admin']),
  'a SUSPENDED admin is not staff — suspension has to take the authority, not just the label'
);
SELECT ok(
  NOT public.is_staff('eee10000-0000-4000-8000-00000000000b', ARRAY['admin']),
  'a RESTRICTED admin is not staff: restriction is a sanction too'
);
SELECT ok(
  NOT public.is_staff('eee10000-0000-4000-8000-00000000000a', ARRAY['super_admin']),
  'a DEACTIVATED super admin is not staff'
);
SELECT ok(
  NOT public.is_staff('eee10000-0000-4000-8000-000000000007', ARRAY['admin','super_admin']),
  'a member is not staff'
);

-- ---------------------------------------------------------------------------
-- audit_log, one principal at a time, acting as the real role
-- ---------------------------------------------------------------------------

SELECT ok(
  NOT has_table_privilege('anon', 'public.audit_log', 'SELECT'),
  'anonymous cannot reach the privileged ledger at all: refused on the table grant, before any policy is consulted'
);

SET LOCAL ROLE authenticated;

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000007","role":"authenticated","aal":"aal1"}', true);
SELECT is((SELECT count(*)::int FROM public.audit_log WHERE action = 'matrix.probe'),
  0, 'a normal member sees no audit rows');

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal2"}', true);
SELECT is((SELECT count(*)::int FROM public.audit_log WHERE action = 'matrix.probe'),
  0, 'a moderator sees no audit rows: working the queue is not the same as reading the ledger');

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal2"}', true);
SELECT is((SELECT count(*)::int FROM public.audit_log WHERE action = 'matrix.probe'),
  0, 'support sees no audit rows');

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2"}', true);
SELECT is((SELECT count(*)::int FROM public.audit_log WHERE action = 'matrix.probe'),
  0, 'an analyst sees no audit rows: aggregates are not the ledger');

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000006","role":"authenticated","aal":"aal2"}', true);
SELECT is((SELECT count(*)::int FROM public.audit_log WHERE action = 'matrix.probe'),
  1, 'a read-only auditor sees the ledger — that is the role');

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}', true);
SELECT is((SELECT count(*)::int FROM public.audit_log WHERE action = 'matrix.probe'),
  1, 'an active admin sees the ledger');

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
SELECT is((SELECT count(*)::int FROM public.audit_log WHERE action = 'matrix.probe'),
  1, 'a super admin sees the ledger');

-- The regression this whole migration exists for. Before 20261018090000 this
-- returned 1, through PostgREST, with a live token.
SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000009","role":"authenticated","aal":"aal2"}', true);
SELECT is((SELECT count(*)::int FROM public.audit_log WHERE action = 'matrix.probe'),
  0, 'a SUSPENDED admin sees nothing: suspension revokes ledger access');

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-00000000000a","role":"authenticated","aal":"aal2"}', true);
SELECT is((SELECT count(*)::int FROM public.audit_log WHERE action = 'matrix.probe'),
  0, 'a DEACTIVATED super admin sees nothing');

RESET ROLE;

-- ---------------------------------------------------------------------------
-- The same shape on a second table, so the fix is not audit_log-specific
-- ---------------------------------------------------------------------------

SET LOCAL ROLE authenticated;

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);
SELECT is((SELECT count(*)::int FROM public.analytics_events WHERE name = 'matrix.probe'),
  1, 'an active super admin sees analytics events');

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-00000000000a","role":"authenticated","aal":"aal2"}', true);
SELECT is((SELECT count(*)::int FROM public.analytics_events WHERE name = 'matrix.probe'),
  0, 'a deactivated super admin does not');

RESET ROLE;

-- ---------------------------------------------------------------------------
-- service_role
-- ---------------------------------------------------------------------------

SELECT ok(
  (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'service_role'),
  'service_role bypasses RLS entirely, which is precisely why the service-role client must never be reachable from the browser'
);

-- ---------------------------------------------------------------------------
-- Structural invariants: what keeps the matrix true for tables nobody has
-- thought to add a row for yet
-- ---------------------------------------------------------------------------

SELECT is(
  (SELECT count(*)::int
     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND NOT c.relrowsecurity
      AND (has_table_privilege('anon', c.oid, 'SELECT')
        OR has_table_privilege('authenticated', c.oid, 'SELECT'))),
  0,
  'no table is readable by anon or authenticated with RLS switched off — a grant without RLS is every row, to everyone'
);

SELECT is(
  (SELECT count(*)::int FROM pg_policies
    WHERE schemaname = 'public'
      AND (qual LIKE '%user_role%' OR with_check LIKE '%user_role%')
      AND coalesce(qual, '') NOT LIKE '%is_staff%'),
  0,
  'every policy that decides on a staff role delegates to is_staff instead of restating it — thirteen private copies of the rule is how the account-status check went missing'
);

-- csam_incidents, reports and admin_broadcasts carry policies and no SELECT
-- grant, so they are unreachable by every principal including super_admin.
-- For csam_incidents that is deliberate as of 20261017090000: reads go through
-- audited RPCs. Pinned so a future GRANT has to be a decision rather than an
-- accident — which is exactly how the CSAM queue broke.
SELECT is(
  (SELECT count(*)::int FROM (VALUES ('csam_incidents'),('reports'),('admin_broadcasts')) t(rel)
    WHERE has_table_privilege('authenticated', ('public.' || t.rel)::regclass, 'SELECT')),
  0,
  'the RPC-only tables stay unreadable directly: no SELECT grant to authenticated on csam_incidents, reports or admin_broadcasts'
);

SELECT * FROM finish();
ROLLBACK;
