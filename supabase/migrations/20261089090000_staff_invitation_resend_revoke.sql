-- Resending and revoking staff invitations.
--
-- The console does the Auth side (send the invitation again; delete an
-- account whose setup never finished, which kills its link). This records each
-- action before the console acts, under MFA and a rate limit, and refuses
-- anything that is not an unfinished invitation: an operator who completed
-- setup is changed through the normal access controls, never "revoked".
BEGIN;

CREATE FUNCTION public.admin_note_staff_invitation(p_target UUID, p_action TEXT, p_reason TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  actor   UUID := auth.uid();
  target  public.users%ROWTYPE;
  pending BOOLEAN;
BEGIN
  IF NOT public.is_staff(actor, ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  PERFORM private.require_aal2();
  IF p_target IS NULL OR p_action IS NULL OR p_action NOT IN ('resent','revoked')
     OR p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 500 THEN
    RAISE EXCEPTION 'invalid_input';
  END IF;
  IF p_target = actor THEN RAISE EXCEPTION 'self_change'; END IF;
  IF NOT public.claim_rate_limit('staff_invitation_' || p_action, 3600, 20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO target FROM public.users WHERE user_id = p_target;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
  SELECT COALESCE(raw_app_meta_data ->> 'staff_invite_pending' = 'true', false) INTO pending
    FROM auth.users WHERE id = p_target;
  IF NOT COALESCE(pending, false) THEN RAISE EXCEPTION 'invitation_not_pending'; END IF;
  -- Resending re-grants nothing, so the account must still hold its staff
  -- role. Revoking runs after the role is removed, so it must not.
  IF p_action = 'resent' AND target.user_role::TEXT = 'normal' THEN RAISE EXCEPTION 'invitation_not_pending'; END IF;
  IF p_action = 'revoked' AND target.user_role::TEXT <> 'normal' THEN RAISE EXCEPTION 'invitation_access_exists'; END IF;
  PERFORM private.record_operational_audit(actor, 'staff_invitation_' || p_action, 'user', p_target,
    target.anonymous_pseudonym,
    btrim(p_reason),
    jsonb_build_object('role', target.user_role::TEXT));
END $$;
REVOKE ALL ON FUNCTION public.admin_note_staff_invitation(UUID,TEXT,TEXT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_note_staff_invitation(UUID,TEXT,TEXT) TO authenticated;

SELECT public.record_migration('20261089090000', 'staff_invitation_resend_revoke');
COMMIT;
