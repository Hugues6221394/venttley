-- ============================================================================
-- Venttly | Migration 0004 — Username/password auth + zero-PII recovery
--
-- v1 moves from Supabase anonymous auth to username + password. To stay
-- zero-PII the client maps a username to a synthetic internal handle
-- (`<lower(username)>@id.venttly.app`) and uses Supabase email+password auth;
-- the password is the real credential.
--
-- Account recovery is client-side and infrastructure-free: at signup the
-- client encrypts the password into a blob with an Argon2id-derived key from
-- a 12-word recovery phrase. The blob + salt live on the user row. During
-- recovery (pre-auth) the client reads them through `fetch_recovery_material`,
-- derives the key from the phrase, decrypts the password, and signs in.
-- ============================================================================

-- The pseudonym is now the login handle — enforce case-insensitive uniqueness.
CREATE UNIQUE INDEX IF NOT EXISTS users_pseudonym_lower_unique
    ON public.users (lower(anonymous_pseudonym));

-- Recovery material (AES-GCM blob of the password + the Argon2id salt).
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS recovery_blob TEXT,
    ADD COLUMN IF NOT EXISTS recovery_salt TEXT;

-- Re-assert column-level SELECT grants (migration 0003 pattern). The recovery
-- columns are NOT granted — clients read them only via the RPC below.
REVOKE SELECT ON public.users FROM anon, authenticated;
GRANT SELECT (
    user_id,
    anonymous_pseudonym,
    avatar_seed,
    current_mood,
    user_role,
    is_verified,
    account_status,
    safety_tier,
    birth_year,
    created_at,
    updated_at
) ON public.users TO anon, authenticated;

-- Pre-auth recovery read: returns the encrypted blob for a username. The blob
-- is useless without the 12-word phrase, so exposing it to `anon` is safe.
CREATE OR REPLACE FUNCTION public.fetch_recovery_material(p_username TEXT)
RETURNS TABLE (recovery_blob TEXT, recovery_salt TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.recovery_blob, u.recovery_salt
    FROM public.users u
    WHERE lower(u.anonymous_pseudonym) = lower(p_username)
    LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.fetch_recovery_material(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fetch_recovery_material(TEXT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
