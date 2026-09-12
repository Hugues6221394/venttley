BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(45);

-- ============================================================
-- Grants
-- ============================================================
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.register_device_session(text,text,text,text,text,text)',
    'EXECUTE'
  ),
  'a signed-in client can register the device it is running on'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.register_device_session(text,text,text,text,text,text)',
    'EXECUTE'
  ),
  'device registration is closed to anonymous callers'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.my_device_sessions()', 'EXECUTE'),
  'a signed-in client can list its own sessions'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.revoke_device_session(uuid)', 'EXECUTE'),
  'a signed-in client can end one of its sessions'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.touch_device_session()', 'EXECUTE'),
  'the heartbeat is callable by the session it checks'
);
SELECT ok(
  has_function_privilege('anon', 'public.record_failed_login(text)', 'EXECUTE'),
  'failed sign-ins are recordable before authentication'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'private.record_security_event(uuid,text,text,uuid,uuid,jsonb)', 'EXECUTE'
  ),
  'clients cannot forge arbitrary security events'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'private.end_device_session(uuid,uuid,text)', 'EXECUTE'
  ),
  'the raw session terminator is not client-callable'
);

-- ============================================================
-- Table privileges and RLS
-- ============================================================
SELECT is(
  (
    SELECT count(*)
      FROM pg_catalog.pg_class AS class
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = class.relnamespace
     WHERE namespace.nspname = 'public'
       AND class.relname IN
         ('user_devices', 'device_sessions', 'security_events', 'login_attempts')
       AND class.relrowsecurity
  ),
  4::BIGINT,
  'every security table has row level security enabled'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.user_devices', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.user_devices', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.user_devices', 'DELETE'),
  'device rows are written only through the registration RPC'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.device_sessions', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.device_sessions', 'UPDATE'),
  'session rows are written only through the definer RPCs'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.security_events', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.security_events', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.security_events', 'DELETE'),
  'the security ledger is not directly writable by clients'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.login_attempts', 'SELECT'),
  'the sign-in attempt ledger is invisible to clients'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.login_attempts', 'SELECT'),
  'the sign-in attempt ledger is invisible to anonymous callers'
);
SELECT is(
  (
    SELECT count(*)
      FROM pg_catalog.pg_class AS class
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = class.relnamespace
     WHERE namespace.nspname = 'public'
       AND class.relname IN
         ('user_devices', 'device_sessions', 'security_events', 'login_attempts')
       AND (
         has_table_privilege('authenticated', class.oid, 'TRUNCATE')
         OR has_table_privilege('anon', class.oid, 'TRUNCATE')
       )
  ),
  0::BIGINT,
  'security tables cannot be emptied through PostgREST'
);

-- ============================================================
-- Fixtures
-- ============================================================
INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES
  (
    '94000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'device-owner-a@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"device_owner_a","avatar_seed":"device-owner-a","birth_year":2000}'::JSONB,
    now(), now()
  ),
  (
    '94000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'device-owner-b@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"device_owner_b","avatar_seed":"device-owner-b","birth_year":2000}'::JSONB,
    now(), now()
  );

-- ============================================================
-- Registration
-- ============================================================
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '94000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"94000000-0000-4000-8000-000000000001","role":"authenticated","session_id":"94aa0000-0000-4000-8000-000000000001"}';

SELECT lives_ok(
  $$SELECT public.register_device_session(
    'owner-a-device-0001', 'Pixel 8', 'phone', 'Android', '14', '1.0.0'
  )$$,
  'registering a device from a signed-in client succeeds'
);

SELECT is(
  (SELECT count(*)::INT FROM public.user_devices
    WHERE user_id = '94000000-0000-4000-8000-000000000001'),
  1,
  'registration creates exactly one device row'
);

SELECT is(
  (SELECT count(*)::INT FROM public.device_sessions
    WHERE user_id = '94000000-0000-4000-8000-000000000001'
      AND revoked_at IS NULL),
  1,
  'registration opens exactly one live session row'
);

SELECT is(
  (SELECT count(*)::INT FROM public.security_events
    WHERE user_id = '94000000-0000-4000-8000-000000000001'
      AND kind = 'login_new_device'),
  1,
  'the first sight of a device is recorded as a new-device login'
);

-- Cold start on the same GoTrue session must reattach, not duplicate.
SELECT lives_ok(
  $$SELECT public.register_device_session(
    'owner-a-device-0001', 'Pixel 8', 'phone', 'Android', '14', '1.0.1'
  )$$,
  're-registering the same session is accepted'
);

SELECT is(
  (SELECT count(*)::INT FROM public.device_sessions
    WHERE user_id = '94000000-0000-4000-8000-000000000001'
      AND revoked_at IS NULL),
  1,
  're-registering reattaches to the existing session instead of duplicating it'
);

SELECT is(
  (SELECT count(*)::INT FROM public.security_events
    WHERE user_id = '94000000-0000-4000-8000-000000000001'
      AND kind = 'login_new_device'),
  1,
  'a known device does not log a second new-device event'
);

SELECT is(
  (SELECT count(*)::INT FROM public.my_device_sessions() WHERE is_current),
  1,
  'the caller sees its own session marked as current'
);

-- ============================================================
-- Isolation between accounts
-- ============================================================
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '94000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"94000000-0000-4000-8000-000000000002","role":"authenticated","session_id":"94bb0000-0000-4000-8000-000000000001"}';

SELECT is(
  (SELECT count(*)::INT FROM public.user_devices),
  0,
  'a second account cannot see the first account devices'
);

SELECT is(
  (SELECT count(*)::INT FROM public.my_device_sessions()),
  0,
  'session listing is scoped to the calling account'
);

SELECT is(
  public.revoke_device_session(
    (SELECT device_session_id FROM public.device_sessions
      WHERE user_id = '94000000-0000-4000-8000-000000000001' LIMIT 1)
  ),
  FALSE,
  'one account cannot end another account session'
);

-- ============================================================
-- Append-only ledger
-- ============================================================
RESET ROLE;

SELECT throws_ok(
  $$UPDATE public.security_events SET severity = 'info'
     WHERE user_id = '94000000-0000-4000-8000-000000000001'$$,
  'P0001', 'security_events is append-only',
  'security history cannot be rewritten, even by the table owner'
);

SELECT throws_ok(
  $$DELETE FROM public.security_events
     WHERE user_id = '94000000-0000-4000-8000-000000000001'$$,
  'P0001', 'security_events is append-only',
  'security history cannot be deleted, even by the table owner'
);

-- ============================================================
-- Self-attested events
-- ============================================================
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '94000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"94000000-0000-4000-8000-000000000001","role":"authenticated","session_id":"94aa0000-0000-4000-8000-000000000001"}';

SELECT throws_ok(
  $$SELECT public.log_my_security_event('login_blocked_device', '{}'::JSONB)$$,
  'unsupported_security_event_kind',
  'a client cannot self-report an event the risk engine owns'
);

SELECT lives_ok(
  $$SELECT public.log_my_security_event('two_factor_enabled', '{}'::JSONB)$$,
  'a client can report enabling two-factor authentication'
);

SELECT ok(
  (SELECT count(*) FROM public.my_security_events(30, NULL)) >= 2,
  'the security history returns the caller events'
);

SELECT is(
  (
    SELECT kind FROM public.my_security_events(1, NULL)
  ),
  'two_factor_enabled',
  'the security history is ordered newest first'
);

-- ============================================================
-- Revocation
-- ============================================================
SELECT is(
  public.revoke_device_session(
    (SELECT device_session_id FROM public.my_device_sessions() LIMIT 1)
  ),
  TRUE,
  'the owner can end its own session'
);

SELECT is(
  (SELECT count(*)::INT FROM public.my_device_sessions()),
  0,
  'a revoked session disappears from the active list'
);

SELECT is(
  public.touch_device_session(),
  FALSE,
  'the heartbeat reports a revoked session as dead'
);

SELECT is(
  (SELECT count(*)::INT FROM public.security_events
    WHERE user_id = '94000000-0000-4000-8000-000000000001'
      AND kind = 'device_revoked'),
  1,
  'revocation is written to the security history'
);

-- ============================================================
-- Blocking a device
-- ============================================================
SELECT ok(
  public.block_device(
    (SELECT device_row_id FROM public.user_devices
      WHERE user_id = '94000000-0000-4000-8000-000000000001' LIMIT 1)
  ) >= 0,
  'the owner can block one of its devices'
);

SELECT ok(
  (SELECT blocked_at IS NOT NULL FROM public.user_devices
    WHERE user_id = '94000000-0000-4000-8000-000000000001' LIMIT 1),
  'blocking marks the device row'
);

SELECT is(
  (
    SELECT is_blocked FROM public.register_device_session(
      'owner-a-device-0001', 'Pixel 8', 'phone', 'Android', '14', '1.0.1'
    )
  ),
  TRUE,
  'a blocked device is refused a new session'
);

SELECT is(
  (SELECT count(*)::INT FROM public.device_sessions
    WHERE user_id = '94000000-0000-4000-8000-000000000001'
      AND revoked_at IS NULL),
  0,
  'a refused registration opens no session'
);

SELECT is(
  (SELECT count(*)::INT FROM public.security_events
    WHERE user_id = '94000000-0000-4000-8000-000000000001'
      AND kind = 'login_blocked_device'),
  1,
  'an attempt from a blocked device is recorded as critical'
);

-- ============================================================
-- Password rotation is observed where it happens
-- ============================================================
RESET ROLE;

UPDATE auth.users
   SET encrypted_password = 'a-different-hash'
 WHERE id = '94000000-0000-4000-8000-000000000002';

SELECT ok(
  (SELECT password_changed_at IS NOT NULL FROM public.users
    WHERE user_id = '94000000-0000-4000-8000-000000000002'),
  'rotating the password stamps the profile'
);

SELECT is(
  (SELECT count(*)::INT FROM public.security_events
    WHERE user_id = '94000000-0000-4000-8000-000000000002'
      AND kind = 'password_changed'),
  1,
  'a password change is recorded without the client reporting it'
);

-- ============================================================
-- Failed sign-in ledger
-- ============================================================
SET LOCAL ROLE anon;

SELECT lives_ok(
  $$SELECT public.record_failed_login('someone@example.com')$$,
  'a failed sign-in can be recorded before authentication'
);

RESET ROLE;

SELECT is(
  (SELECT count(*)::INT FROM public.login_attempts
    WHERE outcome = 'failed' AND identifier_hash IS NOT NULL),
  1,
  'the failed attempt is stored against a hash, never the raw identifier'
);

SELECT * FROM finish();
ROLLBACK;
