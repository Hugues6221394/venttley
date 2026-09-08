BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(6);

-- An authorization matrix over the catalog rather than a hand-written list of
-- function names. The point is that it covers functions nobody has written
-- yet: a new admin_* RPC added without a REVOKE, or with an is_staff check
-- forgotten, fails this file without anyone remembering to update it.
--
-- It exists because this branch shipped several defects of exactly this shape
-- that reading the code did not catch:
--
--   * admin_authorize_password_reset and admin_finalize_password_reset were
--     created with no REVOKE/GRANT, so they kept Postgres's default EXECUTE TO
--     PUBLIC and were reachable by anon.
--   * admin_reset_user_password had been revoked from every role including
--     service_role, so a Server Action pointed at it would have failed for
--     every request — a build cannot see a missing grant.
--   * admin_log was revoked from authenticated, which silently broke the login
--     audit for months.

-- ---------------------------------------------------------------------------
-- 1. Nothing named admin_* may be reachable without signing in.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT COALESCE(string_agg(p.proname || '(' ||
            pg_get_function_identity_arguments(p.oid) || ')', ', ' ORDER BY p.proname), '')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname LIKE 'admin\_%'
      AND has_function_privilege('anon', p.oid, 'EXECUTE')),
  '', 'no admin_* function is callable by anon'
);

-- ---------------------------------------------------------------------------
-- 2. Every admin_* function decides for itself who may call it. A GRANT to
--    `authenticated` is not authorization — every member of the app holds that
--    role — so the body must consult the caller's staff role.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname LIKE 'admin\_%'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND p.prosrc NOT ILIKE '%is_staff%'
      AND p.prosrc NOT ILIKE '%user_role%'),
  '', 'every admin_* function reachable by a signed-in caller checks the caller''s role'
);

-- ---------------------------------------------------------------------------
-- 3. A function that writes must not be marked STABLE or IMMUTABLE. PostgREST
--    runs those in a READ ONLY transaction, so the write fails only over the
--    API — which is how admin_global_search shipped broken and passed in psql.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname LIKE 'admin\_%'
      AND p.provolatile <> 'v'
      AND (p.prosrc ILIKE '%INSERT INTO%'
           OR p.prosrc ILIKE '%UPDATE %'
           OR p.prosrc ILIKE '%DELETE FROM%'
           OR p.prosrc ILIKE '%admin_log(%')),
  '', 'no admin_* function that writes is marked STABLE or IMMUTABLE'
);

-- ---------------------------------------------------------------------------
-- 4. SECURITY DEFINER without a pinned search_path is a privilege-escalation
--    shape: a caller who can create objects in an earlier schema can shadow
--    what the function resolves.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname LIKE 'admin\_%'
      AND p.prosecdef
      AND NOT EXISTS (
        SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) c
         WHERE c LIKE 'search\_path=%')),
  '', 'every SECURITY DEFINER admin_* function pins its search_path'
);

-- ---------------------------------------------------------------------------
-- 5. The hardest-to-reverse operations require a completed MFA step-up at the
--    database, not only in the Next.js proxy that a direct PostgREST call
--    skips entirely.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT COALESCE(string_agg(f, ', ' ORDER BY f), '')
     FROM unnest(ARRAY['admin_delete_user','admin_set_user_role',
                       'admin_authorize_password_reset',
                       'admin_resolve_csam_incident']) f
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = f
         AND p.prosrc ILIKE '%require_aal2%')),
  '', 'deletion, role assignment, password reset and CSAM resolution all require AAL2'
);

-- ---------------------------------------------------------------------------
-- 6. admin_log stays unreachable by clients. It takes an arbitrary action and
--    target, so a caller holding it could forge an audit entry against someone
--    else. Narrow wrappers like admin_log_login() are the sanctioned route.
-- ---------------------------------------------------------------------------
SELECT ok(
  NOT has_function_privilege('authenticated',
        'public.admin_log(text,text,uuid,text,jsonb,jsonb,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon',
        'public.admin_log(text,text,uuid,text,jsonb,jsonb,text,jsonb)', 'EXECUTE'),
  'admin_log cannot be called directly by a client, so audit rows cannot be forged'
);

SELECT * FROM finish();
ROLLBACK;
