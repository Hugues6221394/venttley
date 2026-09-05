-- Show people their own recovery address and number in full.
--
-- my_recovery_methods returned private.mask_email(...) — do***@gmail.com. That
-- was the wrong instinct applied in the wrong place. Masking exists to stop a
-- THIRD party learning an address: staff reading a moderation queue, a security
-- alert that might be forwarded, a log someone exports. None of that describes
-- this call. my_recovery_methods is SECURITY DEFINER and reads exactly one row,
-- the caller's own, behind a session that already carries the password. Anyone
-- who can see this response can already change the address outright, so hiding
-- its middle protects nothing from them.
--
-- What it does do is defeat the row's only purpose. "do***@gmail.com" does not
-- tell somebody with two Gmail accounts which inbox to open, and it does not
-- let them notice they typed a typo eleven months ago. On the recovery screen,
-- ambiguity is not a privacy feature — it is how people end up locked out of
-- an account they could otherwise have recovered.
--
-- So the owner now gets the real value. The masked form is returned alongside
-- it rather than dropped, because it is still the right thing to render in a
-- confirmation snackbar, and callers that pass it onward should not have to
-- re-derive it.
--
-- Where masking stays, deliberately:
--   * security_events.context — staff can read these
--   * confirm_recovery_email / _phone event payloads, same reason
--   * report_reporter_for_staff and the rest of the moderation surface
-- Those are the cases the helper was written for, and they are untouched.

BEGIN;

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
      -- The caller's own address, unredacted. Scoped to auth.uid() above.
      'address', v_row.recovery_email,
      'masked', private.mask_email(v_row.recovery_email),
      'verified', v_row.recovery_email_verified,
      'pending', v_row.recovery_email IS NOT NULL AND NOT v_row.recovery_email_verified,
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

-- set_recovery_email returns what the client puts in "we sent a code to X".
-- That sentence is useless masked — the whole question the reader has is which
-- inbox to go and open.
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

  RETURN v_email;
END $$;

REVOKE ALL ON FUNCTION public.set_recovery_email(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_recovery_email(TEXT) TO authenticated;

-- Same for the phone: the client echoes this back as "we texted X".
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

  RETURN v_phone;
END $$;

REVOKE ALL ON FUNCTION public.set_recovery_phone(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_recovery_phone(TEXT) TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20260913090000', 'show_own_recovery_in_full'
);

NOTIFY pgrst, 'reload schema';
