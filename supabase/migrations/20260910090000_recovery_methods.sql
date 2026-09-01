-- A recovery email and phone that are separate from how you log in.
--
-- What existed: setRecoveryEmail called auth.updateUser(email:), which
-- REPLACES the account's login address. On an anonymous account that silently
-- changed what the person signs in with — add hugues@gmail.com as "recovery"
-- and tester_user@id.venttly.app stops working. Surprising, and on an
-- anonymity-first app arguably a privacy regression. It also failed outright,
-- because Supabase's secure-email-change tried to confirm to the old synthetic
-- address and rejected the whole call while the mail to the new address had
-- already gone — an error on screen and a message in the inbox.
--
-- What this adds: one recovery email and one recovery phone, each with its own
-- pending/verified state, neither touching the login identity. Email and phone
-- SIGN-UP still work exactly as before — those set auth.users.email/phone and
-- are untouched here. A person can sign up with an email and still nominate a
-- different address for recovery.
--
-- REUSES 0072 RATHER THAN REPLACING IT
--
-- 0072 already got the hard parts right: a 6-digit code, only the salted
-- SHA-256 hash stored, 15-minute expiry, a 60-second resend gate, and the code
-- burned after 6 wrong guesses. Its _hash_verify_code is reused verbatim. What
-- 0072 verifies is auth.users.email — the login address — which for an
-- anonymous account is synthetic and therefore proves nothing. This applies the
-- same machinery to an address the person actually reads.
--
-- WHY CODES AND NOT LINKS
--
-- Mail providers and corporate security gateways prefetch URLs before a human
-- opens the message, so a one-time link can be consumed by a scanner and the
-- person is told "invalid or expired". A code cannot be spent by being read.
-- Deep links would also need apple-app-site-association and assetlinks.json
-- served from a domain that currently has no A record, and would break for
-- anybody reading mail on a desktop.
--
-- PHONE IS BUILT BUT INERT UNTIL SMS EXISTS
--
-- We do not send SMS ourselves and are not going to invent an SMS outbox. A
-- recovery phone is only marked verified when it matches a number GoTrue has
-- already confirmed on the account, so ownership is proven by the same OTP the
-- phone sign-in flow uses. Until an SMS provider is configured in Supabase,
-- confirm_recovery_phone will correctly refuse — the schema is ready and the
-- feature is honest about being unavailable.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Where the methods live
-- ---------------------------------------------------------------------------

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS recovery_email           TEXT,
  ADD COLUMN IF NOT EXISTS recovery_email_verified  BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS recovery_email_added_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS recovery_phone           TEXT,
  ADD COLUMN IF NOT EXISTS recovery_phone_verified  BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS recovery_phone_added_at  TIMESTAMPTZ;

COMMENT ON COLUMN public.users.recovery_email IS
  'Address for account recovery. Independent of the login identity in auth.users.';

ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_recovery_email_shape;
ALTER TABLE public.users
  ADD CONSTRAINT users_recovery_email_shape CHECK (
    recovery_email IS NULL
    OR (
      recovery_email = lower(recovery_email)
      AND recovery_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
      AND length(recovery_email) BETWEEN 6 AND 320
      -- The synthetic login domain is not a recoverable mailbox. Accepting it
      -- would let somebody "recover" through an address nobody can read.
      AND recovery_email NOT LIKE '%@id.venttly.app'
    )
  );

ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_recovery_phone_shape;
ALTER TABLE public.users
  ADD CONSTRAINT users_recovery_phone_shape CHECK (
    recovery_phone IS NULL OR recovery_phone ~ '^\+[1-9][0-9]{6,14}$'
  );

-- One verified address per person. Unverified duplicates are allowed on
-- purpose: two people mistyping the same address must both be able to try, and
-- only the one who proves ownership keeps it. Without the partial predicate, a
-- stranger could park an address you were about to verify.
CREATE UNIQUE INDEX IF NOT EXISTS users_recovery_email_verified_unique
  ON public.users (recovery_email)
  WHERE recovery_email_verified AND recovery_email IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS users_recovery_phone_verified_unique
  ON public.users (recovery_phone)
  WHERE recovery_phone_verified AND recovery_phone IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Codes, one per person per purpose
-- ---------------------------------------------------------------------------
--
-- Separate from 0072's email_verification_codes, which is keyed by user alone.
-- Sharing it would mean verifying a login email and a recovery email fought
-- over the same row and cancelled each other.
CREATE TABLE IF NOT EXISTS public.recovery_verification_codes (
  user_id    UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  purpose    TEXT NOT NULL CHECK (purpose IN ('email', 'phone')),
  target     TEXT NOT NULL,
  code_hash  TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  attempts   INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, purpose)
);

COMMENT ON TABLE public.recovery_verification_codes IS
  'Pending recovery-method codes. Only the salted hash is stored; the code exists in the email and nowhere else.';

ALTER TABLE public.recovery_verification_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.recovery_verification_codes FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Masking, for display
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.mask_email(p_email TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_email IS NULL OR position('@' in p_email) < 2 THEN NULL
    ELSE left(split_part(p_email, '@', 1), 2) || '***@' || split_part(p_email, '@', 2)
  END;
$$;

CREATE OR REPLACE FUNCTION private.mask_phone(p_phone TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_phone IS NULL OR length(p_phone) < 6 THEN NULL
    ELSE left(p_phone, 4) || ' *** *** ' || right(p_phone, 3)
  END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Recovery email: request, confirm, remove
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_recovery_email(p_email TEXT)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me    UUID := (SELECT auth.uid());
  v_email TEXT := lower(btrim(COALESCE(p_email, '')));
  v_last  TIMESTAMPTZ;
  v_code  TEXT;
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

  -- Pending, never verified by the act of typing it.
  UPDATE public.users
     SET recovery_email = v_email,
         recovery_email_verified = FALSE,
         recovery_email_added_at = now()
   WHERE user_id = v_me;

  v_code := lpad((floor(random() * 1000000))::INT::TEXT, 6, '0');

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

  -- Straight into the outbox with an explicit recipient. queue_email resolves
  -- the address from the account, which is exactly what must not happen here —
  -- the point is to reach an address the account does not own yet.
  INSERT INTO public.email_outbox (user_id, template, variables, to_address)
  VALUES (v_me, 'verify_email', jsonb_build_object('code', v_code), v_email);

  RETURN private.mask_email(v_email);
END $$;

REVOKE ALL ON FUNCTION public.set_recovery_email(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_recovery_email(TEXT) TO authenticated;

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

  -- Only the address the code was issued for. Without this, someone could
  -- request a code for an address they own, change recovery_email to a
  -- different one, and verify it with the first code.
  UPDATE public.users
     SET recovery_email_verified = TRUE
   WHERE user_id = v_me AND recovery_email = v_row.target;
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
         recovery_email_added_at = NULL
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
-- 5. Recovery phone
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_recovery_phone(p_phone TEXT)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me    UUID := (SELECT auth.uid());
  v_phone TEXT := regexp_replace(COALESCE(p_phone, ''), '[^+0-9]', '', 'g');
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  -- E.164 or nothing. A number without a country code is unusable for SMS and
  -- there is no sensible default to guess.
  IF v_phone !~ '^\+[1-9][0-9]{6,14}$' THEN
    RAISE EXCEPTION 'invalid_phone';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.users u
     WHERE u.recovery_phone = v_phone
       AND u.recovery_phone_verified
       AND u.user_id <> v_me
  ) THEN
    RAISE EXCEPTION 'invalid_phone';
  END IF;

  UPDATE public.users
     SET recovery_phone = v_phone,
         recovery_phone_verified = FALSE,
         recovery_phone_added_at = now()
   WHERE user_id = v_me;

  RETURN private.mask_phone(v_phone);
END $$;

REVOKE ALL ON FUNCTION public.set_recovery_phone(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_recovery_phone(TEXT) TO authenticated;

-- Marked verified only when GoTrue has already confirmed this exact number on
-- the account, which happens through the same SMS OTP the phone sign-in uses.
-- We send no SMS of our own and invent no second proof of ownership.
CREATE OR REPLACE FUNCTION public.confirm_recovery_phone()
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me       UUID := (SELECT auth.uid());
  v_pending  TEXT;
  v_auth     TEXT;
  v_confirmed TIMESTAMPTZ;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT recovery_phone INTO v_pending
    FROM public.users WHERE user_id = v_me;
  IF v_pending IS NULL THEN RETURN FALSE; END IF;

  SELECT au.phone, au.phone_confirmed_at INTO v_auth, v_confirmed
    FROM auth.users au WHERE au.id = v_me;

  -- GoTrue stores the number without a leading +.
  IF v_confirmed IS NULL
     OR v_auth IS NULL
     OR ('+' || regexp_replace(v_auth, '[^0-9]', '', 'g')) <> v_pending THEN
    RETURN FALSE;
  END IF;

  UPDATE public.users
     SET recovery_phone_verified = TRUE
   WHERE user_id = v_me;

  INSERT INTO public.security_events (user_id, kind, severity, context)
  VALUES (v_me, 'recovery_email_changed', 'info',
          jsonb_build_object('method', 'phone',
                             'masked', private.mask_phone(v_pending),
                             'state', 'verified'));

  RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.confirm_recovery_phone() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_recovery_phone() TO authenticated;

CREATE OR REPLACE FUNCTION public.clear_recovery_phone()
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
     SET recovery_phone = NULL,
         recovery_phone_verified = FALSE,
         recovery_phone_added_at = NULL
   WHERE user_id = v_me;
  DELETE FROM public.recovery_verification_codes
   WHERE user_id = v_me AND purpose = 'phone';
  INSERT INTO public.security_events (user_id, kind, severity, context)
  VALUES (v_me, 'recovery_email_changed', 'warning',
          jsonb_build_object('method', 'phone', 'state', 'removed'));
  RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.clear_recovery_phone() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.clear_recovery_phone() TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. What the settings screen reads
-- ---------------------------------------------------------------------------
--
-- Masked, always. The full address is never sent back to a client: it is
-- already known to whoever typed it, and returning it turns a stolen session
-- into a way of harvesting the owner's real email.
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
      'masked', private.mask_email(v_row.recovery_email),
      'verified', v_row.recovery_email_verified,
      'pending', v_row.recovery_email IS NOT NULL AND NOT v_row.recovery_email_verified,
      'code_expires_at', v_pending_until,
      'added_at', v_row.recovery_email_added_at
    ),
    'phone', jsonb_build_object(
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
  '20260910090000', 'recovery_methods'
);

NOTIFY pgrst, 'reload schema';
