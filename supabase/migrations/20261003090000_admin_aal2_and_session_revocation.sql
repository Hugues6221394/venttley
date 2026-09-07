-- Enforce AAL2 for the highest-risk admin_* RPCs at the database boundary,
-- and revoke sessions on the three events admin/README.md calls out: a staff
-- role being removed, an account being suspended, and credentials being
-- reset.
--
-- Today 100% of AAL2/TOTP enforcement lives in admin/proxy.ts, which reads
-- the session's assurance level client-side via the Supabase Auth SDK. That
-- is Next.js middleware: it only runs for requests that go through the
-- Next.js router. A caller with a valid AAL1 access token who invokes
-- public.rpc("admin_delete_user", ...) directly against PostgREST — never
-- touching a Next.js route — hits the database with no step-up check at all,
-- the same "enforced only in application code, not at the trust boundary"
-- shape as the lib/roles.ts fail-open already fixed in this series. Every
-- admin_* RPC's authorization today is exclusively is_staff() role checks;
-- none look at assurance level.

-- =========================================================================
-- 1) Read the caller's AAL straight from the JWT claims GoTrue issues, the
--    same defensive-read convention private.current_auth_session_id() already
--    uses for session_id (20260828230000_device_sessions_and_security_events.sql).
-- =========================================================================

CREATE OR REPLACE FUNCTION private.current_aal()
RETURNS TEXT
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE
  v_claims TEXT;
BEGIN
  v_claims := NULLIF(current_setting('request.jwt.claims', TRUE), '');
  IF v_claims IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN NULLIF(v_claims::JSONB ->> 'aal', '');
EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION private.current_aal() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.require_aal2()
RETURNS VOID
LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  IF private.current_aal() IS DISTINCT FROM 'aal2' THEN
    RAISE EXCEPTION 'aal2_required: this action requires a completed MFA step-up, not just a signed-in session'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION private.require_aal2() FROM PUBLIC, anon, authenticated;

-- =========================================================================
-- 2) Gate the highest-risk RPCs: permanent deletion, role assignment
--    (privilege escalation surface), password reset (account takeover
--    surface), and CSAM incident resolution (this repo's own comment on
--    0094_csam_pipeline.sql calls this "the most sensitive data in the
--    system"). Ordinary moderation (suspend/ban/shadow-ban, report
--    resolution) stays at AAL1 — moderators triage these routinely and the
--    README doesn't ask for step-up there; this list matches the
--    super_admin-only, hardest-to-reverse tier.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.admin_delete_user(
    p_target UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before JSONB; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can delete users';
    END IF;
    PERFORM private.require_aal2();
    IF p_target = auth.uid() THEN
        RAISE EXCEPTION 'you cannot delete your own account here';
    END IF;

    SELECT to_jsonb(u), '@' || u.anonymous_pseudonym INTO v_before, v_label
      FROM users u WHERE u.user_id = p_target;
    IF v_before IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    -- Audit first — the target rows are about to vanish.
    PERFORM admin_log('user.delete', 'user', p_target, v_label, v_before, NULL, p_reason, '{}'::jsonb);
    DELETE FROM auth.users   WHERE id = p_target;
    DELETE FROM public.users WHERE user_id = p_target;
END $$;

CREATE OR REPLACE FUNCTION public.admin_set_user_role(
    p_target UUID,
    p_role   TEXT,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before TEXT; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can set roles';
    END IF;
    PERFORM private.require_aal2();

    SELECT user_role::text, '@' || anonymous_pseudonym
      INTO v_before, v_label
      FROM users WHERE user_id = p_target;
    IF v_before IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    UPDATE users SET user_role = p_role::user_role_type, updated_at = now()
     WHERE user_id = p_target;

    PERFORM admin_log(
        'user.set_role', 'user', p_target, v_label,
        jsonb_build_object('user_role', v_before),
        jsonb_build_object('user_role', p_role),
        p_reason, '{}'::jsonb
    );

    -- A role change means whatever JWT/session this member is carrying no
    -- longer matches reality. Force re-authentication rather than leaving an
    -- old session to keep working until it happens to expire.
    DELETE FROM auth.sessions WHERE user_id = p_target;
END $$;

-- admin_reset_user_password (0104_admin_user_ops.sql) mutated auth.users
-- directly via pgcrypto and was deliberately retired for exactly that reason:
-- "GoTrue owns auth.users password lifecycle. Direct SQL hash mutation can
-- drift from the Auth service's current contract." (see
-- 20260728174036_retire_direct_auth_password_mutation.sql, which REVOKEd
-- EXECUTE from PUBLIC, anon, authenticated, AND service_role — nobody can
-- call it anymore). The earlier migration in this series
-- (20261002090000_admin_rpc_hardening.sql) briefly re-created this function's
-- body without noticing the revocation, which is a dead end: CREATE OR
-- REPLACE preserves existing grants, so the "fixed" function was still
-- unreachable by every role, and pointing the Server Action's resetPassword
-- action at it (via the RPC helper, which requires `authenticated` EXECUTE)
-- would have thrown "permission denied for function" for every real request.
-- Caught by testing the RPC directly rather than only typechecking; that
-- migration's password-reset section has been removed.
--
-- The actual fix respects the GoTrue-ownership boundary: the mutation itself
-- stays on the Auth Admin API (auth.admin.updateUserById), called from
-- Next.js server code with the service-role key, same as before this series
-- started. What moves into the database is everything that was previously
-- duplicated or missing around that call — is_staff, AAL2, and the
-- recovery-phrase guard, consolidated into one authorization RPC — plus a
-- second RPC to audit and revoke sessions once the Auth Admin API call has
-- actually succeeded. Audit can't be made transactionally atomic with a
-- mutation that happens in a different system over the network; staging it
-- immediately after the call succeeds is the closest available to it, and is
-- an honest description of the constraint rather than a claim of atomicity
-- SQL can't actually deliver here.

CREATE OR REPLACE FUNCTION public.admin_authorize_password_reset(
    p_target UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_recovery_blob TEXT; v_found BOOLEAN;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can reset passwords';
    END IF;
    PERFORM private.require_aal2();

    SELECT true, recovery_blob INTO v_found, v_recovery_blob
      FROM users WHERE user_id = p_target;
    IF v_found IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
    IF v_recovery_blob IS NOT NULL THEN
        RAISE EXCEPTION 'this account is protected by a recovery phrase; the member must recover or change the password with that phrase';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION public.admin_finalize_password_reset(
    p_target UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can reset passwords';
    END IF;

    SELECT '@' || anonymous_pseudonym INTO v_label FROM users WHERE user_id = p_target;
    IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    -- The entire point of a forced reset is that the account may be
    -- compromised. A new password that leaves an attacker's existing session
    -- alive has not actually locked them out — they never need the password
    -- again until that session happens to expire or gets refreshed.
    DELETE FROM auth.sessions WHERE user_id = p_target;

    -- Never log the password itself.
    PERFORM admin_log(
        'user.reset_password', 'user', p_target, v_label,
        NULL, NULL, p_reason, '{}'::jsonb
    );
END $$;

CREATE OR REPLACE FUNCTION public.admin_resolve_csam_incident(
    p_incident_id UUID,
    p_status      TEXT,
    p_report_ref  TEXT DEFAULT NULL,
    p_notes       TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rec RECORD;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.users u
                    WHERE u.user_id = auth.uid() AND u.user_role = 'super_admin') THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    PERFORM private.require_aal2();
    IF p_status NOT IN ('reported','cleared','false_positive') THEN
        RAISE EXCEPTION 'invalid status %', p_status;
    END IF;

    UPDATE public.csam_incidents
       SET status = p_status, report_reference = p_report_ref,
           reviewed_by = auth.uid(), reviewed_at = now(), notes = p_notes
     WHERE incident_id = p_incident_id
     RETURNING * INTO v_rec;
    IF v_rec.incident_id IS NULL THEN RAISE EXCEPTION 'incident not found'; END IF;

    -- Only a confirmed false positive restores the content.
    IF p_status = 'false_positive' THEN
        IF v_rec.kind = 'post' THEN
            UPDATE posts SET media_status = 'clean', deleted_at = NULL
             WHERE post_id = v_rec.content_ref;
        ELSE
            UPDATE whispers SET media_status = 'clean', deleted_at = NULL
             WHERE whisper_id = v_rec.content_ref;
        END IF;
    END IF;

    PERFORM admin_log('csam.resolve', 'csam_incident', p_incident_id, NULL,
                      NULL, jsonb_build_object('status', p_status, 'report_reference', p_report_ref),
                      p_notes, '{}'::jsonb);
END $$;

-- =========================================================================
-- 3) Suspend/ban also revokes sessions ("an account is suspended", per the
--    README). Shadow-ban is deliberately excluded — its entire mechanism is
--    that the affected member cannot tell it happened, and forcing them
--    straight back to a login screen would announce it.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.admin_set_user_status(
    p_target UUID,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before JSONB; v_label TEXT; v_after JSONB;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    IF p_status NOT IN ('active','suspended','banned','shadow_banned') THEN
        RAISE EXCEPTION 'invalid status %', p_status;
    END IF;
    SELECT to_jsonb(u), '@' || u.anonymous_pseudonym INTO v_before, v_label
      FROM users u WHERE u.user_id = p_target;
    IF v_before IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    UPDATE users SET account_status = p_status, updated_at = now()
     WHERE user_id = p_target;

    SELECT to_jsonb(u) INTO v_after FROM users u WHERE u.user_id = p_target;

    PERFORM admin_log(
        'user.set_status', 'user', p_target, v_label,
        jsonb_build_object('account_status', v_before->>'account_status'),
        jsonb_build_object('account_status', v_after->>'account_status'),
        p_reason, '{}'::jsonb
    );

    IF p_status IN ('suspended', 'banned') THEN
        DELETE FROM auth.sessions WHERE user_id = p_target;
    END IF;
END $$;

-- admin_suspend_user_ladder is a second path to the same 'suspended' state
-- admin_set_user_status covers above (the escalating temp-ban ladder), so it
-- needs the same session revocation for the same reason.
CREATE OR REPLACE FUNCTION public.admin_suspend_user_ladder(
    p_target UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_count    INT;
    v_label    TEXT;
    v_duration INTERVAL;
    v_until    TIMESTAMPTZ;
    v_tier     TEXT;
    v_before   JSONB;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT suspension_count, '@' || anonymous_pseudonym, to_jsonb(u)
      INTO v_count, v_label, v_before
      FROM users u WHERE u.user_id = p_target;
    IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    v_duration := CASE v_count
                    WHEN 0 THEN interval '24 hours'
                    WHEN 1 THEN interval '7 days'
                    WHEN 2 THEN interval '30 days'
                    ELSE NULL           -- permanent
                  END;
    v_until := CASE WHEN v_duration IS NULL THEN NULL ELSE now() + v_duration END;
    v_tier  := CASE v_count
                    WHEN 0 THEN '24h'
                    WHEN 1 THEN '7d'
                    WHEN 2 THEN '30d'
                    ELSE 'permanent'
               END;

    UPDATE users
       SET account_status   = 'suspended',
           suspended_until  = v_until,
           suspension_count = suspension_count + 1,
           updated_at       = now()
     WHERE user_id = p_target;

    PERFORM admin_log(
        'user.suspend_ladder', 'user', p_target, v_label,
        jsonb_build_object('account_status', v_before->>'account_status',
                           'suspension_count', v_count),
        jsonb_build_object('account_status', 'suspended',
                           'suspension_count', v_count + 1,
                           'suspended_until', v_until, 'tier', v_tier),
        p_reason, jsonb_build_object('tier', v_tier)
    );

    DELETE FROM auth.sessions WHERE user_id = p_target;

    RETURN jsonb_build_object('tier', v_tier, 'suspended_until', v_until,
                              'suspension_count', v_count + 1);
END $$;

-- The ledger has to be able to tell whether this ran.
SELECT public.record_migration(
  '20261003090000', 'admin_aal2_and_session_revocation'
);

NOTIFY pgrst, 'reload schema';
