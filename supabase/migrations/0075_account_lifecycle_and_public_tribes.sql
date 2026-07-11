-- ---------------------------------------------------------------------------
-- Venttly | Migration 0075 — Account lifecycle + public tribes on profiles
-- ---------------------------------------------------------------------------
-- Two features:
--
--  1. Self-serve account controls
--     - Deactivate (reversible): the account instantly disappears from the
--       app. Logging back in reactivates it (see reactivate_my_account, which
--       the client calls on every successful session restore).
--     - Delete (30-day grace): flags deletion_requested_at. The account is
--       deactivated immediately; if the user does not log back in within 30
--       days, purge_due_accounts() permanently removes their data. Logging in
--       during the window cancels the deletion.
--
--  2. user_public_tribes(): powers the "Tribes" section on a public profile.
--     Anonymity-first — a private tribe is only revealed to a viewer who is
--     also a member of it. Public tribes are shown to everyone.
-- ---------------------------------------------------------------------------

-- 1) Lifecycle columns ------------------------------------------------------
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS deactivated_at        TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS deletion_requested_at TIMESTAMPTZ;

-- Others may read deactivated_at (to hide the profile); the deletion clock
-- stays private to the owner + service role.
GRANT SELECT (deactivated_at) ON public.users TO authenticated, anon;

-- Deactivate: reversible hide. Clears any pending deletion.
CREATE OR REPLACE FUNCTION public.deactivate_my_account()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'Not signed in.'; END IF;
    UPDATE public.users
       SET deactivated_at        = now(),
           deletion_requested_at = NULL
     WHERE user_id = v_me;
END $$;

-- Request deletion: deactivate now + start the 30-day clock.
CREATE OR REPLACE FUNCTION public.request_account_deletion()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'Not signed in.'; END IF;
    UPDATE public.users
       SET deactivated_at        = COALESCE(deactivated_at, now()),
           deletion_requested_at = now()
     WHERE user_id = v_me;
END $$;

-- Reactivate: called by the client after a successful login. Restores a
-- deactivated account and cancels a pending deletion if within the window.
CREATE OR REPLACE FUNCTION public.reactivate_my_account()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RETURN; END IF;
    UPDATE public.users
       SET deactivated_at        = NULL,
           deletion_requested_at = NULL
     WHERE user_id = v_me
       AND (deactivated_at IS NOT NULL OR deletion_requested_at IS NOT NULL);
END $$;

-- Purge: hard-delete app data for accounts past the 30-day grace. Auth-user
-- removal is done by the account-purge edge function (service role); this
-- clears the public schema rows it owns. FK cascades handle child rows.
CREATE OR REPLACE FUNCTION public.purge_due_accounts()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count INT := 0;
BEGIN
    WITH due AS (
        DELETE FROM public.users
         WHERE deletion_requested_at IS NOT NULL
           AND deletion_requested_at < now() - INTERVAL '30 days'
        RETURNING user_id
    )
    SELECT count(*) INTO v_count FROM due;
    RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.deactivate_my_account()     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_account_deletion()  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reactivate_my_account()     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_due_accounts()        FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.deactivate_my_account()    TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_account_deletion() TO authenticated;
GRANT EXECUTE ON FUNCTION public.reactivate_my_account()    TO authenticated;
-- purge_due_accounts is invoked by the scheduled service-role job only.

-- 2) Public tribes for a profile -------------------------------------------
-- Returns the tribe_directory rows for tribes the target belongs to, hiding
-- private tribes the viewer is not also a member of.
CREATE OR REPLACE FUNCTION public.user_public_tribes(p_target UUID)
RETURNS SETOF public.tribe_directory
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    SELECT d.*
      FROM public.tribe_directory d
      JOIN public.tribe_members m
        ON m.tribe_id = d.tribe_id
       AND m.user_id = p_target
     WHERE d.is_private = false
        OR EXISTS (
             SELECT 1 FROM public.tribe_members viewer
              WHERE viewer.tribe_id = d.tribe_id
                AND viewer.user_id = auth.uid()
           )
     ORDER BY d.member_count DESC;
$$;

REVOKE ALL ON FUNCTION public.user_public_tribes(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.user_public_tribes(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
