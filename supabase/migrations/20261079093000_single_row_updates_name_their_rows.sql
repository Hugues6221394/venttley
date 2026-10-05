-- PostgREST sessions preload pg_safeupdate, which rejects UPDATE without a WHERE
-- clause. These single-row control updates passed direct SQL tests but failed
-- through the API ("UPDATE requires a WHERE clause"), so enabling staff
-- notifications and five other release controls never took effect.
-- Bodies are unchanged apart from the explicit WHERE.

CREATE OR REPLACE FUNCTION private.invalidate_attention_rollout()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  IF NEW.enabled IS DISTINCT FROM OLD.enabled THEN
    UPDATE private.staff_attention_snapshots SET invalidated=true WHERE true;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_configure_access_reviews(p_operation uuid, p_enabled boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE actor UUID:=auth.uid(); request JSONB:=jsonb_build_object('enabled',p_enabled);
BEGIN
  IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  IF p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
  IF private.admin_operation_existing(actor,p_operation,'access_review.configure',request) IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('access_review_configure',3600,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  UPDATE private.access_review_control SET enabled=p_enabled WHERE true;
  PERFORM private.record_admin_operation(actor,p_operation,'access_review.configure',request,p_operation);
  PERFORM private.record_operational_audit(actor,'access_review_configured','access_review_control',NULL,'access reviews','Changed access-review availability.',request);
END $function$;

CREATE OR REPLACE FUNCTION public.admin_configure_invitation_ledger(p_operation uuid, p_enabled boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE actor UUID:=auth.uid(); request JSONB:=jsonb_build_object('enabled',p_enabled);
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
 PERFORM private.require_aal2();
 IF p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
 IF private.admin_operation_existing(actor,p_operation,'invitation.configure',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('invitation_configure',3600,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 UPDATE private.staff_invitation_control SET enabled=p_enabled WHERE true;
 PERFORM private.record_admin_operation(actor,p_operation,'invitation.configure',request,p_operation);
 PERFORM private.record_operational_audit(actor,'invitation_ledger_configured','staff_invitation_control',NULL,'staff invitations','Changed invitation ledger availability.',request);
END $function$;

CREATE OR REPLACE FUNCTION public.admin_configure_invitation_setup_repair(p_operation uuid, p_enabled boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE actor UUID:=auth.uid(); request JSONB:=jsonb_build_object('enabled',p_enabled);
BEGIN
  PERFORM private.require_invitation_setup_actor();
  IF p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
  IF private.admin_operation_existing(actor,p_operation,'invitation.setup_control',request) IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('invitation_setup_control',3600,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  PERFORM 1 FROM private.staff_invitation_control FOR UPDATE;
  PERFORM 1 FROM public.users WHERE user_id=actor FOR SHARE;
  PERFORM private.require_invitation_setup_actor();
  UPDATE private.staff_invitation_control SET setup_repair_enabled=p_enabled WHERE true;
  PERFORM private.record_admin_operation(actor,p_operation,'invitation.setup_control',request,p_operation);
  PERFORM private.record_operational_audit(actor,'invitation_setup_control_changed','staff_invitation_control',NULL,
    'staff invitations','Changed availability of narrow invitation setup repair.',request);
END $function$;

CREATE OR REPLACE FUNCTION public.service_configure_promotion_approvals(p_operation uuid, p_enabled boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE previous BOOLEAN;
BEGIN
 IF p_operation IS NULL OR p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
 PERFORM 1 FROM private.promotion_control FOR UPDATE;
 SELECT enabled INTO previous FROM private.promotion_control_events WHERE operation_id=p_operation;
 IF FOUND THEN
   IF previous IS DISTINCT FROM p_enabled THEN RAISE EXCEPTION 'idempotency_payload_mismatch'; END IF;
   RETURN;
 END IF;
 IF p_enabled AND (SELECT count(*) FROM (SELECT 1 FROM public.users WHERE user_role='super_admin' AND account_status='active' AND deactivated_at IS NULL LIMIT 2)s)<2 THEN RAISE EXCEPTION 'two_existing_super_admins_required'; END IF;
 UPDATE private.promotion_control SET enabled=p_enabled WHERE true;
 INSERT INTO private.promotion_control_events(operation_id,enabled) VALUES(p_operation,p_enabled);
END $function$;

CREATE OR REPLACE FUNCTION public.service_configure_broadcast_approvals(p_operation uuid, p_enabled boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE previous BOOLEAN;
BEGIN
 IF p_operation IS NULL OR p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
 PERFORM 1 FROM private.broadcast_approval_control FOR UPDATE;
 SELECT enabled INTO previous FROM private.broadcast_approval_controls WHERE operation_id=p_operation;
 IF FOUND THEN
   IF previous IS DISTINCT FROM p_enabled THEN RAISE EXCEPTION 'idempotency_payload_mismatch'; END IF;
   RETURN;
 END IF;
 IF p_enabled AND (SELECT count(*) FROM (SELECT 1 FROM public.users WHERE user_role='super_admin'
   AND account_status='active' AND deactivated_at IS NULL LIMIT 2)s)<2 THEN RAISE EXCEPTION 'two_existing_super_admins_required'; END IF;
 UPDATE private.broadcast_approval_control SET enabled=p_enabled WHERE true;
 INSERT INTO private.broadcast_approval_controls(operation_id,enabled) VALUES(p_operation,p_enabled);
END $function$;

-- Every migration records itself, so the app can tell a database that is
-- behind the build from one that is current. Added by the ledger guard, not
-- by the author of the change above.
SELECT public.record_migration('20261079093000', 'single_row_updates_name_their_rows');
