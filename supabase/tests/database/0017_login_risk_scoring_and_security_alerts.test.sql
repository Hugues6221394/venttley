BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(55);

-- ============================================================
-- Grants
-- ============================================================
SELECT ok(
  has_function_privilege(
    'authenticated', 'public.resolve_suspicious_login(uuid,boolean)', 'EXECUTE'
  ),
  'a signed-in client can answer a "was this you?" prompt'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.resolve_suspicious_login(uuid,boolean)', 'EXECUTE'
  ),
  'adjudicating a sign-in requires being signed in'
);
SELECT ok(
  has_function_privilege(
    'authenticated', 'public.my_unresolved_security_alerts()', 'EXECUTE'
  ),
  'a signed-in client can list its own unanswered prompts'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'private.evaluate_login_risk(uuid,uuid,boolean,text)', 'EXECUTE'
  ),
  'clients cannot invoke the scorer directly'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'private.raise_security_alert(uuid,text,text,text,jsonb,boolean,text,jsonb)',
    'EXECUTE'
  ),
  'clients cannot forge a security alert or send themselves mail'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'private.risk_weight(text)', 'EXECUTE'),
  'clients cannot read the scoring policy one weight at a time'
);

-- ============================================================
-- The policy table
-- ============================================================
SELECT ok(
  (
    SELECT class.relrowsecurity
      FROM pg_catalog.pg_class AS class
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = class.relnamespace
     WHERE namespace.nspname = 'public'
       AND class.relname = 'security_risk_weights'
  ),
  'the risk weight table has row level security enabled'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.security_risk_weights', 'SELECT'),
  'signed-in clients cannot read the thresholds they are being measured against'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.security_risk_weights', 'SELECT'),
  'anonymous callers cannot read the thresholds either'
);
SELECT is(
  (SELECT count(*)::INT FROM public.security_risk_weights),
  6,
  'the four signals and two thresholds are seeded'
);

-- ============================================================
-- Notification kinds
-- ============================================================
INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES
  (
    '95000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'riskowner-a@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"risk_owner_a","avatar_seed":"risk-owner-a","birth_year":2000}'::JSONB,
    now(), now()
  ),
  (
    '95000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'riskowner-b@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"risk_owner_b","avatar_seed":"risk-owner-b","birth_year":2000}'::JSONB,
    now(), now()
  );

SELECT lives_ok(
  $$INSERT INTO public.notifications (user_id, kind, payload)
    VALUES ('95000000-0000-4000-8000-000000000001', 'security_alert', '{}'::JSONB)$$,
  'the notification contract accepts the security kinds'
);
SELECT throws_ok(
  $$INSERT INTO public.notifications (user_id, kind, payload)
    VALUES ('95000000-0000-4000-8000-000000000001', 'security_nonsense', '{}'::JSONB)$$,
  '23514',
  NULL,
  'the notification contract still rejects a kind nobody defined'
);

DELETE FROM public.notifications
 WHERE user_id = '95000000-0000-4000-8000-000000000001';

-- Registration returns a row rather than a scalar, and each call can only be
-- made once. Park the results so several assertions can read the same sign-in.
CREATE TEMP TABLE reg_result (
  label              TEXT,
  device_row_id      UUID,
  device_session_id  UUID,
  is_new_device      BOOLEAN,
  is_blocked         BOOLEAN,
  risk_score         INT,
  needs_confirmation BOOLEAN
);
GRANT INSERT, SELECT ON reg_result TO authenticated;

-- ============================================================
-- A familiar sign-in: new hardware, nothing else
-- ============================================================
UPDATE public.users SET last_country = 'GB'
 WHERE user_id = '95000000-0000-4000-8000-000000000001';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '95000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"95000000-0000-4000-8000-000000000001","role":"authenticated","session_id":"95aa0000-0000-4000-8000-000000000001"}';

INSERT INTO reg_result
SELECT 'd1', * FROM public.register_device_session(
  'risk-a-device-0001', 'Pixel 8', 'phone', 'Android', '14', '1.0.0'
);

SELECT is(
  (SELECT risk_score FROM reg_result WHERE label = 'd1'),
  30,
  'a first-ever device scores the new-device weight and nothing more'
);
SELECT is(
  (SELECT needs_confirmation FROM reg_result WHERE label = 'd1'),
  FALSE,
  'a merely unfamiliar device does not interrupt the user for an answer'
);
SELECT is(
  (SELECT count(*)::INT FROM public.security_events
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND kind = 'suspicious_login'),
  0,
  'thirty points is below the alert threshold, so nothing is flagged'
);
SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND kind = 'security_new_device'),
  1,
  'a new device still earns a line in the inbox'
);
SELECT is(
  (SELECT count(*)::INT FROM public.email_outbox
    WHERE user_id = '95000000-0000-4000-8000-000000000001'),
  0,
  'a new device alone is not worth an email'
);

-- ============================================================
-- Same account, unfamiliar country
-- ============================================================
RESET ROLE;
UPDATE public.users SET last_country = 'NG'
 WHERE user_id = '95000000-0000-4000-8000-000000000001';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '95000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"95000000-0000-4000-8000-000000000001","role":"authenticated","session_id":"95aa0000-0000-4000-8000-000000000002"}';

INSERT INTO reg_result
SELECT 'd2', * FROM public.register_device_session(
  'risk-a-device-0002', 'iPhone 15', 'phone', 'iOS', '17', '1.0.0'
);

SELECT is(
  (SELECT risk_score FROM reg_result WHERE label = 'd2'),
  65,
  'a new device in a country the account has never used adds both weights'
);
SELECT is(
  (SELECT needs_confirmation FROM reg_result WHERE label = 'd2'),
  FALSE,
  'sixty-five clears the alert bar but not the challenge bar'
);
SELECT is(
  (SELECT count(*)::INT FROM public.security_events
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND kind = 'suspicious_login'),
  1,
  'crossing the alert threshold records a suspicious sign-in'
);
SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND kind = 'security_suspicious_login'),
  1,
  'the user is told in-app that something looked unusual'
);
SELECT is(
  (SELECT count(*)::INT FROM public.email_outbox
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND template = 'security_alert'),
  1,
  'a flagged sign-in also leaves the app and reaches the inbox'
);

-- A cold start on a session that already exists must not re-alarm.
INSERT INTO reg_result
SELECT 'd2-again', * FROM public.register_device_session(
  'risk-a-device-0002', 'iPhone 15', 'phone', 'iOS', '17', '1.0.1'
);

SELECT is(
  (SELECT count(*)::INT FROM public.security_events
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND kind = 'suspicious_login'),
  1,
  'reattaching to a live session does not raise the same alarm twice'
);
SELECT is(
  (SELECT risk_score FROM reg_result WHERE label = 'd2-again'),
  65,
  'a reattach reports the score the session was opened with'
);

-- ============================================================
-- Failed guesses, then a sign-in from somewhere else again
-- ============================================================
RESET ROLE;
SET LOCAL ROLE anon;
SELECT public.record_failed_login('riskowner-a@id.venttly.app');
SELECT public.record_failed_login('riskowner-a@id.venttly.app');
SELECT public.record_failed_login('riskowner-a@id.venttly.app');

RESET ROLE;
UPDATE public.users SET last_country = 'US'
 WHERE user_id = '95000000-0000-4000-8000-000000000001';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '95000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"95000000-0000-4000-8000-000000000001","role":"authenticated","session_id":"95aa0000-0000-4000-8000-000000000003"}';

INSERT INTO reg_result
SELECT 'd3', * FROM public.register_device_session(
  'risk-a-device-0003', 'Unknown handset', 'phone', 'Android', '13', '1.0.0'
);

SELECT is(
  (SELECT risk_score FROM reg_result WHERE label = 'd3'),
  85,
  'guesses against the account before a new-device sign-in compound the score'
);
SELECT is(
  (SELECT needs_confirmation FROM reg_result WHERE label = 'd3'),
  TRUE,
  'eighty-five demands an explicit answer from the user'
);
SELECT is(
  (SELECT severity FROM public.security_events
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND kind = 'suspicious_login'
    ORDER BY created_at DESC LIMIT 1),
  'critical',
  'a challenge-level sign-in is recorded as critical, not merely a warning'
);
SELECT is(
  (
    SELECT (context -> 'signals' ->> 'recent_failures')::INT
      FROM public.security_events
     WHERE user_id = '95000000-0000-4000-8000-000000000001'
       AND kind = 'suspicious_login'
     ORDER BY created_at DESC LIMIT 1
  ),
  3,
  'the history records why the sign-in was flagged, not just that it was'
);
SELECT is(
  (SELECT count(*)::INT FROM public.email_outbox
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND template IN ('security_alert', 'security_account_change')),
  1,
  'a second alarm inside ten minutes is not a second email'
);

-- ============================================================
-- What still needs an answer
-- ============================================================
SELECT is(
  (SELECT count(*)::INT FROM public.my_unresolved_security_alerts()),
  2,
  'both flagged sessions are waiting on the user'
);
SELECT is(
  (SELECT risk_score FROM public.my_unresolved_security_alerts() LIMIT 1),
  85,
  'the riskiest unanswered sign-in is offered first'
);

-- ============================================================
-- Answering the prompts
-- ============================================================
-- From the original phone, which is how this actually happens: you notice the
-- alert on the device you still have, about the one you do not.
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '95000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"95000000-0000-4000-8000-000000000001","role":"authenticated","session_id":"95aa0000-0000-4000-8000-000000000001"}';

-- "Yes, that was me"
SELECT is(
  public.resolve_suspicious_login(
    (SELECT device_session_id FROM reg_result WHERE label = 'd2'), TRUE
  ),
  TRUE,
  'confirming a sign-in succeeds'
);
SELECT ok(
  (SELECT trusted_at IS NOT NULL FROM public.user_devices
    WHERE device_row_id = (SELECT device_row_id FROM reg_result WHERE label = 'd2')),
  'confirming vouches for the device so the prompt stops coming back'
);
SELECT ok(
  (SELECT confirmed_at IS NOT NULL FROM public.device_sessions
    WHERE device_session_id = (SELECT device_session_id FROM reg_result WHERE label = 'd2')),
  'the session is marked as adjudicated'
);
SELECT is(
  (SELECT count(*)::INT FROM public.security_events
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND kind = 'suspicious_login_confirmed'),
  1,
  'the answer itself is part of the security history'
);
SELECT is(
  (SELECT count(*)::INT FROM public.my_unresolved_security_alerts()),
  1,
  'an answered prompt stops being offered'
);

-- ============================================================
-- "No, that wasn't me"
-- ============================================================
SELECT is(
  public.resolve_suspicious_login(
    (SELECT device_session_id FROM reg_result WHERE label = 'd3'), FALSE
  ),
  TRUE,
  'rejecting a sign-in succeeds'
);
SELECT ok(
  (SELECT blocked_at IS NOT NULL FROM public.user_devices
    WHERE device_row_id = (SELECT device_row_id FROM reg_result WHERE label = 'd3')),
  'rejecting blocks the hardware, not just the session'
);
SELECT is(
  (SELECT revoked_reason FROM public.device_sessions
    WHERE device_session_id = (SELECT device_session_id FROM reg_result WHERE label = 'd3')),
  'suspicious_rejected',
  'the rejected session is closed with the reason it was closed for'
);
SELECT is(
  (SELECT count(*)::INT FROM public.security_events
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND kind = 'suspicious_login_rejected'),
  1,
  'the rejection is recorded as critical history'
);
SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND kind = 'security_alert'),
  1,
  'the user is told what was done on their behalf and what to do next'
);
SELECT is(
  (SELECT count(*)::INT FROM public.my_unresolved_security_alerts()),
  0,
  'nothing is left waiting once both prompts are answered'
);

-- Rejecting from the suspicious session itself is allowed and deliberately
-- does not sign the caller out mid-recovery. Blocking the device is what
-- closes it: the next heartbeat from that session reports dead, so the
-- intruder is gone within a minute either way.
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '95000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"95000000-0000-4000-8000-000000000001","role":"authenticated","session_id":"95aa0000-0000-4000-8000-000000000003"}';

SELECT is(
  public.touch_device_session(),
  FALSE,
  'the rejected device is evicted by the heartbeat, not left holding a token'
);

-- ============================================================
-- A vouched-for device stops triggering
-- ============================================================
-- Same account, a country it has never seen, and the failed guesses are still
-- inside the hour — a score well over the alert bar. The only thing different
-- is that the user already said this device is theirs.
RESET ROLE;
UPDATE public.users SET last_country = 'FR'
 WHERE user_id = '95000000-0000-4000-8000-000000000001';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '95000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"95000000-0000-4000-8000-000000000001","role":"authenticated","session_id":"95aa0000-0000-4000-8000-000000000004"}';

INSERT INTO reg_result
SELECT 'd2-trusted', * FROM public.register_device_session(
  'risk-a-device-0002', 'iPhone 15', 'phone', 'iOS', '17', '1.0.2'
);

SELECT ok(
  (SELECT risk_score FROM reg_result WHERE label = 'd2-trusted') >= 40,
  'the trusted device still scores above the alert threshold'
);
SELECT is(
  (SELECT count(*)::INT FROM public.security_events
    WHERE user_id = '95000000-0000-4000-8000-000000000001'
      AND kind = 'suspicious_login'),
  2,
  'but a device the user vouched for does not raise a third alarm'
);
SELECT is(
  (SELECT needs_confirmation FROM reg_result WHERE label = 'd2-trusted'),
  FALSE,
  'and it is never challenged again'
);

-- ============================================================
-- Cross-account isolation
-- ============================================================
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '95000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"95000000-0000-4000-8000-000000000002","role":"authenticated","session_id":"95bb0000-0000-4000-8000-000000000001"}';

SELECT is(
  public.resolve_suspicious_login(
    (SELECT device_session_id FROM reg_result WHERE label = 'd1'), FALSE
  ),
  FALSE,
  'one account cannot adjudicate — or block — another account device'
);
SELECT is(
  (SELECT count(*)::INT FROM public.my_unresolved_security_alerts()),
  0,
  'unanswered prompts are scoped to the account that owns them'
);

-- ============================================================
-- Account changes reach the user
-- ============================================================
RESET ROLE;

-- Setting a password for the first time is not a password change.
UPDATE auth.users SET encrypted_password = 'first-hash'
 WHERE id = '95000000-0000-4000-8000-000000000002';

SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = '95000000-0000-4000-8000-000000000002'
      AND kind = 'security_alert'),
  0,
  'a brand new account is not warned that its password was changed'
);

UPDATE auth.users SET encrypted_password = 'rotated-hash'
 WHERE id = '95000000-0000-4000-8000-000000000002';

SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = '95000000-0000-4000-8000-000000000002'
      AND kind = 'security_alert'),
  1,
  'an actual rotation does warn, without the client reporting it'
);
SELECT is(
  (SELECT count(*)::INT FROM public.email_outbox
    WHERE user_id = '95000000-0000-4000-8000-000000000002'
      AND template = 'security_account_change'),
  1,
  'a password change is worth an email even if the app is never opened'
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '95000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"95000000-0000-4000-8000-000000000002","role":"authenticated","session_id":"95bb0000-0000-4000-8000-000000000001"}';

SELECT lives_ok(
  $$SELECT public.log_my_security_event('two_factor_disabled', '{}'::JSONB)$$,
  'a client can report that two-factor was switched off'
);
SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = '95000000-0000-4000-8000-000000000002'
      AND kind = 'security_alert'),
  2,
  'losing two-factor raises an alert of its own'
);
SELECT lives_ok(
  $$SELECT public.log_my_security_event('two_factor_enabled', '{}'::JSONB)$$,
  'turning protection back on is recorded quietly'
);
SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = '95000000-0000-4000-8000-000000000002'
      AND kind = 'security_alert'),
  2,
  'good news does not interrupt anybody'
);

SELECT * FROM finish();
ROLLBACK;
