-- ============================================================================
-- Venttly | Migration 0003 — Security hardening
--
-- Closes a data leak: `recovery_key_hash`, `device_signature_hash`, and
-- `public_key` on public.users were readable by ANY client holding the anon
-- API key, because the users SELECT policy is `USING (true)`.
--
-- Fix strategy: row-level SELECT stays open (pseudonyms + avatars are meant to
-- be public so feeds/threads can render other users), but COLUMN-level SELECT
-- on the three sensitive columns is revoked from the `anon` and
-- `authenticated` roles. RLS remains `USING (true)`; PostgREST can no longer
-- return the secret columns for any row. `service_role` keeps full access.
-- ============================================================================

-- Drop the blanket column SELECT grant, then re-grant only safe columns.
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

-- Intentionally NOT granted to anon/authenticated:
--   recovery_key_hash, device_signature_hash, public_key
-- These are server-side secrets and must never reach a client.

-- INSERT/UPDATE/DELETE column privileges are untouched, so onboarding
-- (which writes recovery_key_hash) keeps working under the existing
-- per-row RLS policies from migration 0002.

-- Nudge PostgREST to refresh its schema cache.
NOTIFY pgrst, 'reload schema';
