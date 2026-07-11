-- 0072_email_verification.sql
--
-- In-app email verification for the OPTIONAL real-email signup path.
--
-- Venttly's core flow is anonymous (synthetic `@id.venttly.app` handles), so
-- Supabase's global "Confirm email" toggle is OFF — otherwise the synthetic
-- addresses, which have no inbox, could never confirm and would lock everyone
-- out. For users who instead sign up with a REAL email (or Google), we verify
-- ownership ourselves with a 6-digit code delivered through the existing
-- `email_outbox` → `email-dispatcher` (Resend) pipeline, and gate sensitive
-- actions behind `users.email_verified`.
--
-- Google / phone signups are considered pre-verified by their provider, so the
-- client marks them verified on first sign-in without a code.

-- 1) Verification flag on the profile row.
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS email_verified BOOLEAN NOT NULL DEFAULT FALSE;

-- 2) One active code per user. We store only the salted SHA-256 hash; the
--    plaintext lives only in the outgoing email.
CREATE TABLE IF NOT EXISTS public.email_verification_codes (
    user_id     UUID PRIMARY KEY REFERENCES public.users(user_id) ON DELETE CASCADE,
    code_hash   TEXT        NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL,
    attempts    INT         NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.email_verification_codes ENABLE ROW LEVEL SECURITY;
-- No direct client access: everything goes through the SECURITY DEFINER RPCs
-- below, so we never expose the hash or let a client forge a row.
REVOKE ALL ON public.email_verification_codes FROM authenticated, anon;

-- pgcrypto's digest() lives in the `extensions` schema on Supabase (that's
-- where `CREATE EXTENSION` puts it), so the search_path must include it —
-- otherwise "function digest(text, unknown) does not exist". Casting 'sha256'
-- to text pins the digest(text, text) overload explicitly.
CREATE OR REPLACE FUNCTION public._hash_verify_code(p_code TEXT, p_user UUID)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public, extensions
AS $$
    SELECT encode(digest(p_code || ':' || p_user::text, 'sha256'::text), 'hex');
$$;

-- 3) Issue a code and queue the email. Rate-limited to one send per 60s.
CREATE OR REPLACE FUNCTION public.request_email_verification()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me    UUID := auth.uid();
    v_code  TEXT;
    v_last  TIMESTAMPTZ;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    -- Already verified? No-op success.
    IF EXISTS (SELECT 1 FROM users WHERE user_id = v_me AND email_verified) THEN
        RETURN TRUE;
    END IF;

    SELECT created_at INTO v_last
      FROM email_verification_codes WHERE user_id = v_me;
    IF v_last IS NOT NULL AND v_last > now() - interval '60 seconds' THEN
        RAISE EXCEPTION 'Please wait a moment before requesting another code.';
    END IF;

    v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');

    INSERT INTO email_verification_codes (user_id, code_hash, expires_at, attempts, created_at)
    VALUES (v_me, public._hash_verify_code(v_code, v_me), now() + interval '15 minutes', 0, now())
    ON CONFLICT (user_id) DO UPDATE
        SET code_hash  = EXCLUDED.code_hash,
            expires_at = EXCLUDED.expires_at,
            attempts   = 0,
            created_at = now();

    -- Reuse the transactional pipeline; dispatcher skips synthetic addresses.
    PERFORM public.queue_email('verify_email', v_me, jsonb_build_object('code', v_code));
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.request_email_verification() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_email_verification() TO authenticated;

-- 4) Confirm a code. Returns true on success, false on mismatch. Wrong codes
--    increment attempts; after 6 tries the code is burned (must re-request).
CREATE OR REPLACE FUNCTION public.confirm_email_verification(p_code TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me  UUID := auth.uid();
    v_row email_verification_codes%ROWTYPE;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT * INTO v_row FROM email_verification_codes WHERE user_id = v_me;
    IF v_row.user_id IS NULL THEN RETURN FALSE; END IF;

    IF v_row.expires_at < now() OR v_row.attempts >= 6 THEN
        DELETE FROM email_verification_codes WHERE user_id = v_me;
        RETURN FALSE;
    END IF;

    IF v_row.code_hash = public._hash_verify_code(coalesce(p_code, ''), v_me) THEN
        UPDATE users SET email_verified = TRUE WHERE user_id = v_me;
        DELETE FROM email_verification_codes WHERE user_id = v_me;
        RETURN TRUE;
    END IF;

    UPDATE email_verification_codes
       SET attempts = attempts + 1 WHERE user_id = v_me;
    RETURN FALSE;
END $$;

REVOKE ALL ON FUNCTION public.confirm_email_verification(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_email_verification(TEXT) TO authenticated;

-- 5) Provider-verified signups (Google / phone) mark themselves verified on
--    first sign-in — their provider already proved ownership.
CREATE OR REPLACE FUNCTION public.mark_email_verified()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    UPDATE users SET email_verified = TRUE WHERE user_id = v_me;
    RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.mark_email_verified() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_email_verified() TO authenticated;

NOTIFY pgrst, 'reload schema';
