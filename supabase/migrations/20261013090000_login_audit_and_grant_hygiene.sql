-- Admin sign-ins were not being audited, and two of my own RPCs were reachable
-- by anon. Both found by enumerating the authorization matrix rather than by
-- reading code, which is the P1 item this migration comes with.
--
-- 1. NOBODY COULD WRITE THE LOGIN AUDIT ROW.
--
-- 20260816092420_restrict_remaining_internal_rpcs.sql revoked admin_log from
-- anon and authenticated, granting it to service_role only, because it takes
-- an arbitrary action string and target — "must never be exposed directly
-- through PostgREST to hostile clients". That reasoning is right: a staff
-- member who can call admin_log directly can forge any audit entry, including
-- one attributing an action to somebody else.
--
-- But admin/app/api/auth/login/route.ts still calls it directly to record the
-- sign-in, wrapped in a try/catch that swallows failures so a logging problem
-- never blocks a login. So every admin sign-in since that migration has failed
-- to audit, silently. Measured: zero rows with action='admin.login', across a
-- database where several sign-ins had happened.
--
-- Nor could it have worked another way. admin_log derives its actor from
-- auth.uid(); service_role has no auth.uid(), so the one role still holding
-- the grant cannot satisfy the function's own precondition. The grant as it
-- stands is only usable from inside other SECURITY DEFINER functions, which is
-- exactly how every admin_* RPC uses it — and is why nothing else broke.
--
-- The fix keeps the restriction and adds a capability narrow enough not to
-- reopen it: admin_log_login() takes no action or target, so it cannot write
-- anything except this one kind of row, about the caller, attributed to the
-- caller. There is nothing to forge.

CREATE OR REPLACE FUNCTION public.admin_log_login(
    p_ip TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_actor UUID := auth.uid(); v_label TEXT;
BEGIN
    -- Staff only. A member signing in to the mobile app has no business
    -- writing to the privileged ledger, and login_attempts already covers
    -- ordinary sign-in telemetry.
    IF NOT is_staff(v_actor, ARRAY['super_admin','admin','moderator','support',
                                   'analyst','read_only_auditor']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT anonymous_pseudonym INTO v_label FROM users WHERE user_id = v_actor;

    -- The action and target are fixed here rather than taken as parameters:
    -- that is the whole reason this can be granted to authenticated when
    -- admin_log cannot.
    PERFORM admin_log(
        'admin.login', 'session', NULL, v_label,
        NULL, NULL, NULL,
        jsonb_strip_nulls(jsonb_build_object('ip', p_ip))
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_log_login(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_log_login(TEXT) TO authenticated;

-- 2. GRANT HYGIENE ON TWO OF MY OWN FUNCTIONS.
--
-- 20261003090000 created admin_authorize_password_reset and
-- admin_finalize_password_reset with no REVOKE/GRANT at all, so they kept
-- Postgres's default EXECUTE TO PUBLIC and were reachable by anon — the only
-- two admin_* functions in the schema that were. Not exploitable, because both
-- check is_staff(auth.uid(), super_admin) and an anonymous caller has no
-- auth.uid(), so they refuse. But every other admin_* function in this
-- codebase revokes from PUBLIC explicitly, and "refused after being called"
-- is not the same as "not callable".

REVOKE ALL ON FUNCTION public.admin_authorize_password_reset(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_authorize_password_reset(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_finalize_password_reset(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_finalize_password_reset(UUID, TEXT) TO authenticated;

SELECT public.record_migration(
  '20261013090000', 'login_audit_and_grant_hygiene'
);

NOTIFY pgrst, 'reload schema';
