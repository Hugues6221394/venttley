-- 0021_users_select_grants.sql
--
-- Fix: PostgrestException 42501 / "permission denied for table users" on
-- login. The `authenticated` and `anon` roles had every table privilege on
-- public.users EXCEPT SELECT, so any client read (post detail joins,
-- pseudonym lookups, sign-in column fetch) was rejected at the Postgres
-- role layer before RLS policies ever ran.
--
-- The fix grants SELECT, but at the COLUMN level: anything readable by RLS
-- on public.users is also reachable by every authenticated client, and the
-- table holds recovery secrets (recovery_blob, recovery_salt, recovery_key
-- hash, device_signature_hash) that absolutely must not leak. Recovery is
-- done via SECURITY DEFINER RPCs that read those columns server-side; no
-- client ever needs them.
--
-- Safe-to-expose columns: identity (user_id, anonymous_pseudonym), display
-- (avatar_seed, current_mood, karma_points), status (user_role, is_verified,
-- account_status, safety_tier), public crypto (public_key), location for
-- local feed (home_city/country/campus), audit (created_at, updated_at).
--
-- Hidden from clients: recovery_blob, recovery_salt, recovery_key_hash,
-- device_signature_hash, birth_year (PII / age).

GRANT SELECT (
    user_id,
    anonymous_pseudonym,
    avatar_seed,
    current_mood,
    user_role,
    is_verified,
    account_status,
    safety_tier,
    public_key,
    karma_points,
    home_city,
    home_country,
    home_campus,
    created_at,
    updated_at
) ON public.users TO authenticated, anon;
