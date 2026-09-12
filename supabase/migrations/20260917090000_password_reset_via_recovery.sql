-- Let a verified recovery email actually recover the account.
--
-- Today the only way back into a locked-out account is the recovery phrase.
-- That is a strong mechanism and a terrible sole mechanism: it is a string of
-- words handed over during signup, at the one moment a person is least
-- invested, and the population this app serves — teenagers, people in crisis,
-- people who signed up at 2am — is exactly the population that will not have
-- kept it. Meanwhile they have carefully added and verified a recovery email
-- that does nothing at the moment they need it.
--
-- So: a code to the verified recovery address, then a new password.
--
-- WHY THIS IS THE MOST DANGEROUS CODE IN THE APP
--
-- Every path here is an unauthenticated path to taking over an account, so the
-- rules are tighter than anywhere else:
--
--   * Only a VERIFIED recovery address is ever accepted. An unproven one would
--     mean anyone who typed an address into their own account could later use
--     it to claim somebody else's.
--   * The response never distinguishes "no such account" from "code sent".
--     Otherwise this becomes an oracle for testing whether an address or a
--     handle has a Venttly account — on an app whose entire promise is that
--     nobody can tell who is here.
--   * Both functions are service_role only. The client never calls them; the
--     password-reset Edge Function does, so rate limiting and enumeration
--     control cannot be bypassed by calling PostgREST directly.
--   * Codes are stored only as a salted hash, expire in 15 minutes, allow six
--     attempts, and are burned on use.
--   * Five requests per account per hour, and a 60-second resend floor.
--
-- The password itself is not set here. Postgres cannot write GoTrue's
-- encrypted_password safely, so complete_password_reset only proves the code
-- and returns the account id; the Edge Function does the update through the
-- admin API and then revokes every existing session, because a reset that
-- leaves an attacker's session alive has not actually recovered anything.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. A third purpose for verification codes
-- ---------------------------------------------------------------------------
--
-- Restating the list currently in force, which is ('email', 'phone') from
-- 20260910090000 — nothing has altered it since. Restating the ORIGINAL list
-- of a constraint that has been widened is how this project has broken
-- migrations before, so the check is deliberate rather than assumed.

ALTER TABLE public.recovery_verification_codes
  DROP CONSTRAINT IF EXISTS recovery_verification_codes_purpose_check;
ALTER TABLE public.recovery_verification_codes
  ADD CONSTRAINT recovery_verification_codes_purpose_check
  CHECK (purpose IN ('email', 'phone', 'password_reset'));

-- ---------------------------------------------------------------------------
-- 2. Request throttling that survives a hostile caller
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.password_reset_attempts (
  user_id      UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS password_reset_attempts_recent_idx
  ON private.password_reset_attempts (user_id, requested_at DESC);

COMMENT ON TABLE private.password_reset_attempts IS
  'One row per reset request, for the hourly cap. In private: no client reads this, and its existence must not be observable.';

REVOKE ALL ON TABLE private.password_reset_attempts
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Request a reset
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.begin_password_reset(p_identifier TEXT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id     TEXT := lower(btrim(COALESCE(p_identifier, '')));
  v_user   UUID;
  v_email  TEXT;
  v_recent INT;
  v_last   TIMESTAMPTZ;
  v_code   TEXT;
BEGIN
  IF length(v_id) = 0 OR length(v_id) > 320 THEN
    RETURN jsonb_build_object('accepted', FALSE, 'reason', 'empty');
  END IF;

  -- Either the address itself or the handle, because somebody locked out does
  -- not necessarily remember which one they are being asked for. Only verified
  -- addresses match: an unproven one is not proof of anything.
  SELECT u.user_id, u.recovery_email
    INTO v_user, v_email
    FROM public.users AS u
   WHERE u.recovery_email_verified
     AND u.recovery_email IS NOT NULL
     AND (
       u.recovery_email = v_id
       OR lower(u.anonymous_pseudonym) = v_id
     )
   LIMIT 1;

  -- No match is not an error and must not look like one. The caller returns
  -- the same thing either way; this branch exists only so the rest of the
  -- function has something to work with.
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('accepted', FALSE, 'reason', 'no_match');
  END IF;

  SELECT count(*) INTO v_recent
    FROM private.password_reset_attempts AS a
   WHERE a.user_id = v_user
     AND a.requested_at > now() - INTERVAL '1 hour';
  IF v_recent >= 5 THEN
    RETURN jsonb_build_object('accepted', FALSE, 'reason', 'rate_limited');
  END IF;

  SELECT created_at INTO v_last
    FROM public.recovery_verification_codes
   WHERE user_id = v_user AND purpose = 'password_reset';
  IF v_last IS NOT NULL AND v_last > now() - INTERVAL '60 seconds' THEN
    RETURN jsonb_build_object('accepted', FALSE, 'reason', 'resend_too_soon');
  END IF;

  v_code := lpad((floor(random() * 1000000))::INT::TEXT, 6, '0');

  INSERT INTO public.recovery_verification_codes
    (user_id, purpose, target, code_hash, expires_at, attempts, created_at)
  VALUES
    (v_user, 'password_reset', v_email,
     public._hash_verify_code(v_code, v_user),
     now() + INTERVAL '15 minutes', 0, now())
  ON CONFLICT (user_id, purpose) DO UPDATE
    SET target     = EXCLUDED.target,
        code_hash  = EXCLUDED.code_hash,
        expires_at = EXCLUDED.expires_at,
        attempts   = 0,
        created_at = now();

  INSERT INTO private.password_reset_attempts (user_id) VALUES (v_user);

  -- To the verified address explicitly, never to the account's login email —
  -- which for an anonymous account is the synthetic @id.venttly.app that
  -- reaches nobody.
  INSERT INTO public.email_outbox (user_id, template, variables, to_address)
  VALUES (v_user, 'password_reset',
          jsonb_build_object('code', v_code), v_email);

  RETURN jsonb_build_object('accepted', TRUE);
END $$;

COMMENT ON FUNCTION public.begin_password_reset(TEXT) IS
  'Issues a reset code to a verified recovery address. service_role only: the caller is responsible for returning an identical response whether or not an account matched.';

REVOKE ALL ON FUNCTION public.begin_password_reset(TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.begin_password_reset(TEXT) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Prove the code
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.complete_password_reset(
  p_identifier TEXT,
  p_code       TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id    TEXT := lower(btrim(COALESCE(p_identifier, '')));
  v_user  UUID;
  v_row   public.recovery_verification_codes;
BEGIN
  SELECT u.user_id INTO v_user
    FROM public.users AS u
   WHERE u.recovery_email_verified
     AND u.recovery_email IS NOT NULL
     AND (
       u.recovery_email = v_id
       OR lower(u.anonymous_pseudonym) = v_id
     )
   LIMIT 1;

  IF v_user IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE);
  END IF;

  SELECT * INTO v_row
    FROM public.recovery_verification_codes
   WHERE user_id = v_user AND purpose = 'password_reset'
     FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE);
  END IF;

  IF v_row.expires_at < now() OR v_row.attempts >= 6 THEN
    DELETE FROM public.recovery_verification_codes
     WHERE user_id = v_user AND purpose = 'password_reset';
    RETURN jsonb_build_object('ok', FALSE);
  END IF;

  IF v_row.code_hash <> public._hash_verify_code(COALESCE(p_code, ''), v_user) THEN
    UPDATE public.recovery_verification_codes
       SET attempts = attempts + 1
     WHERE user_id = v_user AND purpose = 'password_reset';
    RETURN jsonb_build_object('ok', FALSE);
  END IF;

  -- Burned before the password is set, not after. If the admin call fails the
  -- person requests a fresh code, which is a minor annoyance; a reusable code
  -- is an account takeover.
  DELETE FROM public.recovery_verification_codes
   WHERE user_id = v_user AND purpose = 'password_reset';

  RETURN jsonb_build_object('ok', TRUE, 'user_id', v_user);
END $$;

COMMENT ON FUNCTION public.complete_password_reset(TEXT, TEXT) IS
  'Proves a reset code and returns the account id. Does not set the password — GoTrue owns that, and the Edge Function does it through the admin API before revoking every session.';

REVOKE ALL ON FUNCTION public.complete_password_reset(TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_password_reset(TEXT, TEXT)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Record the reset once it has actually happened
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.note_password_reset(p_user UUID)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.users
     SET password_changed_at = now()
   WHERE user_id = p_user;

  INSERT INTO public.security_events (user_id, kind, severity, context)
  VALUES (p_user, 'password_changed', 'warning',
          jsonb_build_object('method', 'recovery_email'));

  -- Tell them it happened, at the address that authorised it. If this was not
  -- them, this mail is the only warning they will get.
  -- headline / detail / when are the variables that template actually reads;
  -- a key it does not know renders as the fallback and the warning goes out
  -- blank, which is the same silent-nothing this whole review keeps finding.
  INSERT INTO public.email_outbox (user_id, template, variables, to_address)
  SELECT p_user, 'security_account_change',
         jsonb_build_object(
           'headline', 'Your password was reset',
           'detail', 'Someone used a code sent to this address to set a new '
                     || 'password. If that was not you, reset it again now — '
                     || 'whoever did this has been signed out.',
           'when', to_char(now(), 'FMDay DD FMMonth YYYY at HH24:MI UTC')
         ),
         u.recovery_email
    FROM public.users AS u
   WHERE u.user_id = p_user
     AND u.recovery_email IS NOT NULL
     AND u.recovery_email_verified;
END $$;

REVOKE ALL ON FUNCTION public.note_password_reset(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.note_password_reset(UUID) TO service_role;

COMMIT;

SELECT public.record_migration(
  '20260917090000', 'password_reset_via_recovery'
);

NOTIFY pgrst, 'reload schema';
