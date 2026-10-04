-- Narrow repair for staff invitations whose setup stalled. Ships disabled.
-- Requires 20261068090000_staff_invitation_ledger and the existing receipt,
-- audit, current_auth_session_id and require_aal2 helpers.
BEGIN;
ALTER TABLE private.staff_invitation_control
  ADD COLUMN setup_repair_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE private.staff_invitation_events DROP CONSTRAINT staff_invitation_events_stage_check;
ALTER TABLE private.staff_invitation_events ADD CONSTRAINT staff_invitation_events_stage_check
  CHECK(stage IN ('reserved','provider_accepted','access_assigned','reconciled','cancelled','setup_repaired'));

CREATE FUNCTION private.require_invitation_setup_actor() RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(),ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  PERFORM private.require_aal2();
  IF NOT EXISTS(SELECT 1 FROM auth.sessions WHERE id=private.current_auth_session_id()
    AND user_id=auth.uid() AND aal::TEXT='aal2'
    AND (not_after IS NULL OR not_after>clock_timestamp())) THEN
    RAISE EXCEPTION 'invitation_session_unavailable';
  END IF;
END $$;
REVOKE ALL ON FUNCTION private.require_invitation_setup_actor() FROM PUBLIC,anon,authenticated,service_role;

-- A delayed original Auth-admin response must not re-enable setup after the
-- repaired invitation has already completed. Preserve this guard on UI rollback.
CREATE FUNCTION private.prevent_repaired_invitation_setup_reopen() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NEW.raw_app_meta_data->'staff_invite_pending'='true'::JSONB
    AND (OLD.raw_app_meta_data->'staff_invite_pending') IS DISTINCT FROM 'true'::JSONB
    AND EXISTS(SELECT 1 FROM private.staff_invitation_attempts i
      JOIN private.staff_invitation_events e ON e.invitation_id=i.invitation_id AND e.stage='setup_repaired'
      WHERE i.invited_user_id=NEW.id) THEN
    RAISE EXCEPTION 'invitation_setup_reopen_forbidden';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER prevent_repaired_invitation_setup_reopen BEFORE UPDATE OF raw_app_meta_data ON auth.users
  FOR EACH ROW EXECUTE FUNCTION private.prevent_repaired_invitation_setup_reopen();
REVOKE ALL ON FUNCTION private.prevent_repaired_invitation_setup_reopen() FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.admin_configure_invitation_setup_repair(p_operation UUID,p_enabled BOOLEAN) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); request JSONB:=jsonb_build_object('enabled',p_enabled);
BEGIN
  PERFORM private.require_invitation_setup_actor();
  IF p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
  IF private.admin_operation_existing(actor,p_operation,'invitation.setup_control',request) IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('invitation_setup_control',3600,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  PERFORM 1 FROM private.staff_invitation_control FOR UPDATE;
  PERFORM 1 FROM public.users WHERE user_id=actor FOR SHARE;
  PERFORM private.require_invitation_setup_actor();
  UPDATE private.staff_invitation_control SET setup_repair_enabled=p_enabled;
  PERFORM private.record_admin_operation(actor,p_operation,'invitation.setup_control',request,p_operation);
  PERFORM private.record_operational_audit(actor,'invitation_setup_control_changed','staff_invitation_control',NULL,
    'staff invitations','Changed availability of narrow invitation setup repair.',request);
END $$;

CREATE FUNCTION public.admin_repair_staff_invitation_setup(p_operation UUID,p_invitation UUID,p_version BIGINT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); i private.staff_invitation_attempts%ROWTYPE;
  u public.users%ROWTYPE; a auth.users%ROWTYPE;
  request JSONB:=jsonb_build_object('invitation',p_invitation,'version',p_version);
BEGIN
  PERFORM private.require_invitation_setup_actor();
  IF p_invitation IS NULL OR p_version IS NULL OR p_version<1 THEN RAISE EXCEPTION 'invalid_input'; END IF;
  IF private.admin_operation_existing(actor,p_operation,'invitation.setup_repair',request) IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('invitation_setup_repair',60,10) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  PERFORM 1 FROM private.staff_invitation_control WHERE enabled AND setup_repair_enabled FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation_setup_repair_disabled'; END IF;
  SELECT * INTO i FROM private.staff_invitation_attempts WHERE invitation_id=p_invitation FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
  IF i.version<>p_version THEN RAISE EXCEPTION 'invitation_conflict'; END IF;
  IF i.cancelled_at IS NOT NULL OR i.grant_expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'invitation_grant_closed'; END IF;
  IF i.state<>'provider_accepted' OR i.invited_user_id IS NULL THEN RAISE EXCEPTION 'invitation_evidence_missing'; END IF;
  -- Stable profile order; serialize with role/status changes, cancellation and
  -- canonical role completion. Derive target from the ledger, never the caller.
  PERFORM 1 FROM public.users WHERE user_id IN (actor,i.invited_user_id) ORDER BY user_id FOR UPDATE;
  PERFORM private.require_invitation_setup_actor();
  SELECT * INTO u FROM public.users WHERE user_id=i.invited_user_id;
  IF u.user_id IS NULL OR u.username_normalized IS DISTINCT FROM i.username_normalized THEN RAISE EXCEPTION 'invitation_binding_mismatch'; END IF;
  IF u.user_role::TEXT IS DISTINCT FROM 'normal' OR u.account_status::TEXT IS DISTINCT FROM 'active'
    OR u.deactivated_at IS NOT NULL OR u.deletion_requested_at IS NOT NULL THEN RAISE EXCEPTION 'invitation_setup_ineligible'; END IF;
  -- This updates only Venttly's server-owned setup marker in the same
  -- transaction as the version, receipt and audit. It does not mint/revoke
  -- tokens, modify password hashes, set confirmation, or send provider mail.
  -- Lock Auth evidence so sign-in/password completion cannot be overwritten.
  SELECT * INTO a FROM auth.users WHERE id=u.user_id FOR UPDATE;
  IF a.id IS NULL OR a.invited_at IS NULL OR a.created_at IS NULL
    OR a.created_at<i.created_at-interval '1 minute' OR a.invited_at<i.created_at-interval '1 minute' THEN
    RAISE EXCEPTION 'invitation_binding_mismatch';
  END IF;
  IF a.last_sign_in_at IS NOT NULL OR a.email_confirmed_at IS NOT NULL
    OR COALESCE(a.encrypted_password,'')<>'' OR COALESCE(a.is_sso_user,false)
    OR (a.banned_until IS NOT NULL AND a.banned_until>clock_timestamp())
    OR jsonb_typeof(COALESCE(a.raw_app_meta_data,'{}'::JSONB))<>'object'
    OR COALESCE(a.raw_app_meta_data,'{}'::JSONB) ? 'staff_invite_pending'
    OR EXISTS(SELECT 1 FROM auth.sessions WHERE user_id=a.id)
    OR EXISTS(SELECT 1 FROM auth.mfa_factors WHERE user_id=a.id) THEN
    RAISE EXCEPTION 'invitation_setup_ineligible';
  END IF;
  IF i.grant_expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'invitation_grant_closed'; END IF;
  UPDATE auth.users SET raw_app_meta_data=COALESCE(raw_app_meta_data,'{}'::JSONB)||'{"staff_invite_pending":true}'::JSONB,
    updated_at=clock_timestamp() WHERE id=a.id;
  UPDATE private.staff_invitation_attempts SET version=version+1 WHERE invitation_id=p_invitation;
  INSERT INTO private.staff_invitation_events(invitation_id,actor_id,stage,version)
    VALUES(p_invitation,actor,'setup_repaired',i.version+1);
  PERFORM private.record_admin_operation(actor,p_operation,'invitation.setup_repair',request,p_invitation);
  PERFORM private.record_operational_audit(actor,'staff_invitation_setup_repaired','staff_invitation',p_invitation,
    'staff invitation','Restored missing setup marker for an unused invitation; no access granted.',
    jsonb_build_object('previous_version',i.version));
END $$;
REVOKE ALL ON FUNCTION public.admin_configure_invitation_setup_repair(UUID,BOOLEAN),
  public.admin_repair_staff_invitation_setup(UUID,UUID,BIGINT) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.admin_configure_invitation_setup_repair(UUID,BOOLEAN),
  public.admin_repair_staff_invitation_setup(UUID,UUID,BIGINT) TO authenticated;
COMMIT;
