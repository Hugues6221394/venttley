-- Make login protection something you cannot walk around.
--
-- Two findings from live testing, one cause.
--
-- 1. Twelve consecutive wrong passwords against /auth/v1/token returned twelve
--    plain 400s. Nothing throttled them. claim_rate_limit never sees that
--    traffic: it guards PostgREST RPCs, and the token endpoint is GoTrue.
--
-- 2. Signing in straight against the API created no device session and no
--    security event. The whole risk pipeline — new device, risk score, "was
--    this you?" — runs in the Flutter client and calls an RPC afterwards. The
--    anon key ships inside the app, so anybody can authenticate without ever
--    tripping any of it.
--
-- Both are the same shape: the checks live somewhere the attacker does not
-- have to go. The only place a password attempt cannot avoid is inside GoTrue
-- itself, which is what a password_verification_attempt hook is.
--
-- So this runs on EVERY password verification, from any client, and:
--   * records the attempt in login_attempts, success or failure;
--   * rejects further attempts once a user crosses the failure threshold;
--   * writes a security event the account holder can actually see.
--
-- ENABLING IT IS A SEPARATE STEP. Creating the function changes nothing until
-- it is selected in Authentication → Hooks. That is deliberate: it means this
-- migration cannot lock anybody out on its own.
--
-- FAILING OPEN, ON PURPOSE
--
-- Every path is wrapped so that an unexpected error returns "continue" rather
-- than an error. A bug in this function must not become an outage that locks
-- an entire userbase out of their accounts. The cost is that a bug also
-- silently disables the protection, so the fallback logs a security event
-- rather than passing quietly.
--
-- NO SECRETS, NO IDENTIFIERS. The hook receives a user id and a boolean. It
-- never sees the password, and it writes no raw identifier and no IP —
-- login_attempts was built that way and this does not change it.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Thresholds live in a table, not in the function body
-- ---------------------------------------------------------------------------

-- The brief asks for configurable thresholds rather than business rules buried
-- in code. An operator changes a row; nobody redeploys anything.
CREATE TABLE IF NOT EXISTS private.auth_guard_settings (
  id                    BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  max_failures          INT NOT NULL DEFAULT 8  CHECK (max_failures BETWEEN 3 AND 100),
  failure_window_secs   INT NOT NULL DEFAULT 900 CHECK (failure_window_secs BETWEEN 60 AND 86400),
  lockout_secs          INT NOT NULL DEFAULT 900 CHECK (lockout_secs BETWEEN 60 AND 86400),
  enabled               BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE private.auth_guard_settings IS
  'Login-guard thresholds. Single row. Operator-editable; never client readable.';

INSERT INTO private.auth_guard_settings (id) VALUES (TRUE)
ON CONFLICT (id) DO NOTHING;

REVOKE ALL ON private.auth_guard_settings FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The hook
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.password_verification_attempt_hook(event JSONB)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user      UUID;
  v_valid     BOOLEAN;
  v_cfg       private.auth_guard_settings%ROWTYPE;
  v_failures  INT;
  v_country   TEXT;
BEGIN
  -- GoTrue sends {"user_id": "<uuid>", "valid": true|false}.
  v_user  := NULLIF(event->>'user_id', '')::UUID;
  v_valid := COALESCE((event->>'valid')::BOOLEAN, FALSE);

  IF v_user IS NULL THEN
    RETURN jsonb_build_object('decision', 'continue');
  END IF;

  SELECT * INTO v_cfg FROM private.auth_guard_settings WHERE id;
  IF NOT FOUND OR NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('decision', 'continue');
  END IF;

  -- The user row may not exist for an auth identity mid-signup; the foreign
  -- keys below would then fail, so nothing is recorded and the attempt passes.
  IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.user_id = v_user) THEN
    RETURN jsonb_build_object('decision', 'continue');
  END IF;

  SELECT u.last_country INTO v_country
    FROM public.users u WHERE u.user_id = v_user;

  IF v_valid THEN
    -- A successful sign-in is recorded here, not in the client, so that a
    -- login from something that is not the app still shows up in the account
    -- holder's security history.
    INSERT INTO public.login_attempts (user_id, outcome, country)
    VALUES (v_user, 'success', v_country);

    INSERT INTO public.security_events (user_id, kind, severity, context)
    VALUES (
      v_user, 'login', 'info',
      jsonb_build_object('source', 'auth_hook', 'country', v_country)
    );

    RETURN jsonb_build_object('decision', 'continue');
  END IF;

  -- Failure path.
  INSERT INTO public.login_attempts (user_id, outcome, country)
  VALUES (v_user, 'failed', v_country);

  SELECT count(*) INTO v_failures
    FROM public.login_attempts a
   WHERE a.user_id = v_user
     AND a.outcome IN ('failed', 'blocked')
     AND a.created_at > now() - make_interval(secs => v_cfg.failure_window_secs);

  IF v_failures >= v_cfg.max_failures THEN
    INSERT INTO public.login_attempts (user_id, outcome, country)
    VALUES (v_user, 'blocked', v_country);

    -- Reuses an existing event kind rather than widening the CHECK
    -- constraint. Adding a value there means restating every other one, and
    -- restating a list from the wrong migration is exactly how the receipts
    -- constraint broke a database earlier in this project.
    INSERT INTO public.security_events (user_id, kind, severity, context)
    VALUES (
      v_user, 'suspicious_login', 'warning',
      jsonb_build_object(
        'reason', 'password_attempts_throttled',
        'failures', v_failures,
        'window_secs', v_cfg.failure_window_secs,
        'country', v_country
      )
    );

    -- Deliberately vague. Confirming "this account exists and is locked"
    -- would turn the throttle into an account-enumeration oracle.
    RETURN jsonb_build_object(
      'decision', 'reject',
      'message', 'Too many attempts. Please wait a few minutes and try again.'
    );
  END IF;

  RETURN jsonb_build_object('decision', 'continue');

EXCEPTION WHEN OTHERS THEN
  -- Never turn a bug in here into a site-wide lockout. Record that the guard
  -- failed, then let the attempt through.
  BEGIN
    INSERT INTO public.security_events (user_id, kind, severity, context)
    VALUES (
      COALESCE(NULLIF(event->>'user_id', '')::UUID, v_user),
      'suspicious_login', 'warning',
      jsonb_build_object('reason', 'auth_guard_error', 'sqlstate', SQLSTATE)
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN jsonb_build_object('decision', 'continue');
END $$;

COMMENT ON FUNCTION public.password_verification_attempt_hook(JSONB) IS
  'GoTrue password_verification_attempt hook: records every attempt and throttles brute force. Enable in Authentication > Hooks.';

-- GoTrue calls this as supabase_auth_admin and nobody else may call it at all.
REVOKE ALL ON FUNCTION public.password_verification_attempt_hook(JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.password_verification_attempt_hook(JSONB)
  TO supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- 3. Letting a locked-out person back in
-- ---------------------------------------------------------------------------

-- Support path: clears the failure streak for one account. The lockout is a
-- rolling window and expires by itself, so this exists for the case where
-- somebody needs in now, not as the normal way out.
CREATE OR REPLACE FUNCTION private.clear_login_failures(p_user_id UUID)
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_removed INT;
BEGIN
  DELETE FROM public.login_attempts a
   WHERE a.user_id = p_user_id
     AND a.outcome IN ('failed', 'blocked');
  GET DIAGNOSTICS v_removed = ROW_COUNT;
  RETURN v_removed;
END $$;

REVOKE ALL ON FUNCTION private.clear_login_failures(UUID)
  FROM PUBLIC, anon, authenticated;

COMMIT;

SELECT public.record_migration(
  '20260903090000', 'auth_login_guard_hook'
);

NOTIFY pgrst, 'reload schema';
