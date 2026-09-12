-- Changing a recovery email must not destroy the one that works.
--
-- Found on a real device. The account had do***@gmail.com verified. Tapping
-- Recovery email → Change it → new address ran:
--
--     UPDATE public.users
--        SET recovery_email = v_email,
--            recovery_email_verified = FALSE
--
-- so the moment the new address was TYPED, the proven one was overwritten and
-- the account's only recovery route became an unconfirmed address. Then the
-- verification mail did not arrive, and the person was left with no way back
-- into their account at all — worse off than before they touched the screen,
-- having done nothing wrong.
--
-- The old address is not recoverable for accounts this already happened to; it
-- was overwritten in place. That is the cost of shipping the destructive
-- version, and it is why this is being fixed before launch rather than after.
--
-- THE SHAPE OF THE FIX
--
-- A verified address and a candidate address are two different facts and now
-- live in two different columns. recovery_email keeps meaning "the address that
-- can recover this account"; recovery_email_pending means "an address someone
-- has asked to switch to, not yet proven". A change writes only the second, so
-- until a code is entered the account's recovery route is exactly what it was.
-- Confirmation promotes pending into place; failure, expiry, or walking away
-- leaves the working address untouched.
--
-- No uniqueness index on the pending column, deliberately. Unverified claims
-- are not exclusive — otherwise typing an address somebody else has merely
-- claimed would tell you they claimed it, and reserving addresses on typing
-- would let one account squat on another's inbox.

BEGIN;

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS recovery_email_pending TEXT;

COMMENT ON COLUMN public.users.recovery_email_pending IS
  'An address requested but not yet proven. Never used for recovery. Promoted into recovery_email by confirm_recovery_email, discarded on failure.';

COMMENT ON COLUMN public.users.recovery_email IS
  'The address that can recover this account. Only replaced once a new address has been proven — see recovery_email_pending.';

-- ---------------------------------------------------------------------------
-- Request: write the candidate, never the live address
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_recovery_email(p_email TEXT)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me       UUID := (SELECT auth.uid());
  v_email    TEXT := lower(btrim(COALESCE(p_email, '')));
  v_last     TIMESTAMPTZ;
  v_code     TEXT;
  v_current  TEXT;
  v_verified BOOLEAN;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  IF v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
     OR length(v_email) > 320 THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;
  IF v_email LIKE '%@id.venttly.app' THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;

  -- Taken by somebody who has proved they own it. Deliberately the same error
  -- as an invalid address: distinguishing them would let anyone test whether a
  -- given address has a Venttly account, on an app whose whole promise is that
  -- nobody can tell who is here.
  IF EXISTS (
    SELECT 1 FROM public.users u
     WHERE u.recovery_email = v_email
       AND u.recovery_email_verified
       AND u.user_id <> v_me
  ) THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;

  SELECT created_at INTO v_last
    FROM public.recovery_verification_codes
   WHERE user_id = v_me AND purpose = 'email';
  IF v_last IS NOT NULL AND v_last > now() - INTERVAL '60 seconds' THEN
    RAISE EXCEPTION 'resend_too_soon';
  END IF;

  SELECT recovery_email, recovery_email_verified
    INTO v_current, v_verified
    FROM public.users WHERE user_id = v_me;

  IF v_verified AND v_current IS NOT NULL AND v_current <> v_email THEN
    -- There is something to lose. Park the candidate and leave the working
    -- address exactly as it is, including its added_at stamp — nothing about
    -- the existing route has changed just because a new one was proposed.
    UPDATE public.users
       SET recovery_email_pending = v_email
     WHERE user_id = v_me;
  ELSE
    -- Nothing verified to protect: either the first address ever, or a retry
    -- of one that was never confirmed. Writing it straight in is safe and
    -- keeps a single unconfirmed address rather than two.
    UPDATE public.users
       SET recovery_email = v_email,
           recovery_email_verified = FALSE,
           recovery_email_added_at = now(),
           recovery_email_pending = NULL
     WHERE user_id = v_me;
  END IF;

  v_code := lpad((floor(random() * 1000000))::INT::TEXT, 6, '0');

  -- target is what confirm_recovery_email checks against, so a code is only
  -- ever good for the address it was mailed to.
  INSERT INTO public.recovery_verification_codes
    (user_id, purpose, target, code_hash, expires_at, attempts, created_at)
  VALUES
    (v_me, 'email', v_email,
     public._hash_verify_code(v_code, v_me), now() + INTERVAL '15 minutes', 0, now())
  ON CONFLICT (user_id, purpose) DO UPDATE
    SET target     = EXCLUDED.target,
        code_hash  = EXCLUDED.code_hash,
        expires_at = EXCLUDED.expires_at,
        attempts   = 0,
        created_at = now();

  -- Explicit recipient: queue_email resolves the address from the account,
  -- which is exactly what must not happen here — the point is to reach an
  -- address the account does not own yet.
  INSERT INTO public.email_outbox (user_id, template, variables, to_address)
  VALUES (v_me, 'verify_email', jsonb_build_object('code', v_code), v_email);

  RETURN v_email;
END $$;

REVOKE ALL ON FUNCTION public.set_recovery_email(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_recovery_email(TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- Confirm: promote the candidate
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.confirm_recovery_email(p_code TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me  UUID := (SELECT auth.uid());
  v_row public.recovery_verification_codes;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT * INTO v_row
    FROM public.recovery_verification_codes
   WHERE user_id = v_me AND purpose = 'email'
     FOR UPDATE;
  IF NOT FOUND THEN RETURN FALSE; END IF;

  IF v_row.expires_at < now() OR v_row.attempts >= 6 THEN
    DELETE FROM public.recovery_verification_codes
     WHERE user_id = v_me AND purpose = 'email';
    RETURN FALSE;
  END IF;

  IF v_row.code_hash <> public._hash_verify_code(COALESCE(p_code, ''), v_me) THEN
    UPDATE public.recovery_verification_codes
       SET attempts = attempts + 1
     WHERE user_id = v_me AND purpose = 'email';
    RETURN FALSE;
  END IF;

  -- The code proves ownership of v_row.target and nothing else. Requiring the
  -- target to be one of the two addresses on the row is what stops a code
  -- issued for an address you own from verifying a different one.
  UPDATE public.users
     SET recovery_email = v_row.target,
         recovery_email_verified = TRUE,
         recovery_email_added_at = now(),
         recovery_email_pending = NULL
   WHERE user_id = v_me
     AND v_row.target IN (recovery_email, recovery_email_pending);
  IF NOT FOUND THEN RETURN FALSE; END IF;

  DELETE FROM public.recovery_verification_codes
   WHERE user_id = v_me AND purpose = 'email';

  INSERT INTO public.security_events (user_id, kind, severity, context)
  VALUES (v_me, 'recovery_email_changed', 'info',
          jsonb_build_object('masked', private.mask_email(v_row.target),
                             'state', 'verified'));

  RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.confirm_recovery_email(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_recovery_email(TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- Abandon a pending change without touching the live address
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cancel_recovery_email_change()
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_me UUID := (SELECT auth.uid());
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  UPDATE public.users
     SET recovery_email_pending = NULL
   WHERE user_id = v_me AND recovery_email_pending IS NOT NULL;
  IF NOT FOUND THEN RETURN FALSE; END IF;

  DELETE FROM public.recovery_verification_codes
   WHERE user_id = v_me AND purpose = 'email';

  RETURN TRUE;
END $$;

COMMENT ON FUNCTION public.cancel_recovery_email_change() IS
  'Discard a requested-but-unproven recovery address. Never touches the verified one, so this is always a safe way out of a half-finished change.';

REVOKE ALL ON FUNCTION public.cancel_recovery_email_change() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_recovery_email_change() TO authenticated;

-- ---------------------------------------------------------------------------
-- Remove clears both
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.clear_recovery_email()
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_me UUID := (SELECT auth.uid());
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  UPDATE public.users
     SET recovery_email = NULL,
         recovery_email_verified = FALSE,
         recovery_email_added_at = NULL,
         recovery_email_pending = NULL
   WHERE user_id = v_me;

  DELETE FROM public.recovery_verification_codes
   WHERE user_id = v_me AND purpose = 'email';

  -- Removing a way back into the account is worth telling the owner about, in
  -- case it was not them who did it.
  INSERT INTO public.security_events (user_id, kind, severity, context)
  VALUES (v_me, 'recovery_email_changed', 'warning',
          jsonb_build_object('state', 'removed'));

  RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.clear_recovery_email() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clear_recovery_email() TO authenticated;

-- ---------------------------------------------------------------------------
-- Report both, so the screen can say "verified, and confirming a new one"
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.my_recovery_methods()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me  UUID := (SELECT auth.uid());
  v_row public.users;
  v_pending_until TIMESTAMPTZ;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT * INTO v_row FROM public.users WHERE user_id = v_me;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;

  SELECT expires_at INTO v_pending_until
    FROM public.recovery_verification_codes
   WHERE user_id = v_me AND purpose = 'email';

  RETURN jsonb_build_object(
    'email', jsonb_build_object(
      -- Unredacted: this is the caller's own row, reached through auth.uid().
      'address', v_row.recovery_email,
      'masked', private.mask_email(v_row.recovery_email),
      'verified', v_row.recovery_email_verified,
      -- An address is awaiting a code either because a change was requested,
      -- or because the only address on the account was never confirmed.
      'pending_address', v_row.recovery_email_pending,
      'pending', v_row.recovery_email_pending IS NOT NULL
                 OR (v_row.recovery_email IS NOT NULL
                     AND NOT v_row.recovery_email_verified),
      'code_expires_at', v_pending_until,
      'added_at', v_row.recovery_email_added_at
    ),
    'phone', jsonb_build_object(
      'address', v_row.recovery_phone,
      'masked', private.mask_phone(v_row.recovery_phone),
      'verified', v_row.recovery_phone_verified,
      'pending', v_row.recovery_phone IS NOT NULL AND NOT v_row.recovery_phone_verified,
      'added_at', v_row.recovery_phone_added_at
    )
  );
END $$;

REVOKE ALL ON FUNCTION public.my_recovery_methods() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_recovery_methods() TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20260914090000', 'pending_recovery_email'
);

NOTIFY pgrst, 'reload schema';
