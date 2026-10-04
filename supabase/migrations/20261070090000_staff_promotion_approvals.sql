-- Two-person approval for staff promotions. Ships disabled (promotion_control).
-- Requires operational governance receipts/audit and existing admin_set_user_role.
BEGIN;
CREATE TABLE private.promotion_control(singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK(singleton),enabled BOOLEAN NOT NULL DEFAULT false);
INSERT INTO private.promotion_control DEFAULT VALUES;
CREATE TABLE private.promotion_control_events(operation_id UUID PRIMARY KEY,enabled BOOLEAN NOT NULL,created_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE private.staff_authority_revisions(user_id UUID PRIMARY KEY,version BIGINT NOT NULL CHECK(version>0));
CREATE TABLE private.staff_promotion_approvals(
 approval_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),target_id UUID NOT NULL,requested_by UUID NOT NULL,
 target_role TEXT NOT NULL,target_revision BIGINT NOT NULL,requester_revision BIGINT NOT NULL,
 reason_code TEXT NOT NULL CHECK(reason_code IN ('operational_coverage','succession','security_oversight')),
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','approved','rejected','cancelled','executed')),
 approved_by UUID,approver_revision BIGINT,approved_at TIMESTAMPTZ,executed_at TIMESTAMPTZ,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),expires_at TIMESTAMPTZ NOT NULL DEFAULT (now()+interval '24 hours'),
 version BIGINT NOT NULL DEFAULT 1 CHECK(version>0),CHECK(target_id<>requested_by),
 CHECK(approved_by IS NULL OR (approved_by<>requested_by AND approved_by<>target_id))
);
CREATE INDEX staff_promotion_cursor ON private.staff_promotion_approvals(created_at DESC,approval_id DESC);
CREATE TABLE private.staff_promotion_events(
 event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,approval_id UUID NOT NULL REFERENCES private.staff_promotion_approvals,
 actor_id UUID NOT NULL,kind TEXT NOT NULL CHECK(kind IN ('requested','approve','reject','cancel','execute')),
 version BIGINT NOT NULL,created_at TIMESTAMPTZ NOT NULL DEFAULT now(),UNIQUE(approval_id,version)
);
-- Ephemeral capability: insert/use/delete in one transaction, never a JWT/GUC.
CREATE TABLE private.staff_promotion_permits(transaction_id BIGINT NOT NULL,target_id UUID NOT NULL,actor_id UUID NOT NULL,
 approval_id UUID NOT NULL REFERENCES private.staff_promotion_approvals,PRIMARY KEY(transaction_id,target_id));
ALTER TABLE private.promotion_control ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.promotion_control_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.staff_authority_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.staff_promotion_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.staff_promotion_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.staff_promotion_permits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.promotion_control,private.promotion_control_events,private.staff_authority_revisions,
 private.staff_promotion_approvals,private.staff_promotion_events,private.staff_promotion_permits FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON SEQUENCE private.staff_promotion_events_event_id_seq FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER promotion_events_immutable BEFORE UPDATE OR DELETE ON private.staff_promotion_events FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();
CREATE TRIGGER promotion_controls_immutable BEFORE UPDATE OR DELETE ON private.promotion_control_events FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();

CREATE FUNCTION public.service_configure_promotion_approvals(p_operation UUID,p_enabled BOOLEAN) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
 UPDATE private.promotion_control SET enabled=p_enabled;
 INSERT INTO private.promotion_control_events(operation_id,enabled) VALUES(p_operation,p_enabled);
END $$;
REVOKE ALL ON FUNCTION public.service_configure_promotion_approvals(UUID,BOOLEAN) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.service_configure_promotion_approvals(UUID,BOOLEAN) TO service_role;

CREATE FUNCTION private.require_promotion_actor(p_mutation BOOLEAN DEFAULT false) RETURNS VOID
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.sessions WHERE id=private.current_auth_session_id() AND user_id=auth.uid()
   AND (not_after IS NULL OR not_after>clock_timestamp()) AND (NOT p_mutation OR aal::TEXT='aal2')) THEN
   RAISE EXCEPTION 'promotion_session_unavailable';
 END IF;
 IF p_mutation THEN PERFORM private.require_aal2(); END IF;
END $$;
REVOKE ALL ON FUNCTION private.require_promotion_actor(BOOLEAN) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.track_staff_authority_revision() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF TG_OP='DELETE' THEN
   IF OLD.user_role::TEXT IN ('super_admin','admin','moderator','support','analyst','read_only_auditor') THEN
     INSERT INTO private.staff_authority_revisions VALUES(OLD.user_id,1) ON CONFLICT(user_id) DO UPDATE SET version=private.staff_authority_revisions.version+1;
   END IF;
   RETURN OLD;
 END IF;
 IF (OLD.user_role,OLD.account_status,OLD.deactivated_at) IS DISTINCT FROM (NEW.user_role,NEW.account_status,NEW.deactivated_at)
 AND (OLD.user_role::TEXT IN ('super_admin','admin','moderator','support','analyst','read_only_auditor') OR NEW.user_role::TEXT IN ('super_admin','admin','moderator','support','analyst','read_only_auditor')) THEN
   INSERT INTO private.staff_authority_revisions VALUES(NEW.user_id,1) ON CONFLICT(user_id) DO UPDATE SET version=private.staff_authority_revisions.version+1;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER track_staff_authority_revision AFTER UPDATE OF user_role,account_status,deactivated_at OR DELETE ON public.users FOR EACH ROW EXECUTE FUNCTION private.track_staff_authority_revision();

CREATE FUNCTION private.enforce_staff_promotion_approval() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.user_role::TEXT<>'super_admin' THEN RETURN NEW; END IF;
 IF TG_OP='UPDATE' AND OLD.user_role::TEXT='super_admin' THEN RETURN NEW; END IF;
 IF NOT EXISTS(SELECT 1 FROM private.promotion_control WHERE enabled) THEN RETURN NEW; END IF;
 IF NOT EXISTS(SELECT 1 FROM private.staff_promotion_permits p JOIN private.staff_promotion_approvals a USING(approval_id)
   WHERE p.transaction_id=txid_current() AND p.target_id=NEW.user_id AND p.actor_id=auth.uid()
   AND a.target_id=NEW.user_id AND a.state='approved' AND a.expires_at>clock_timestamp()) THEN
   RAISE EXCEPTION 'promotion_approval_required';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER enforce_staff_promotion_approval BEFORE INSERT OR UPDATE OF user_role ON public.users FOR EACH ROW EXECUTE FUNCTION private.enforce_staff_promotion_approval();
REVOKE ALL ON FUNCTION private.enforce_staff_promotion_approval(),private.track_staff_authority_revision() FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.admin_request_staff_promotion(p_operation UUID,p_target UUID,p_reason_code TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); result UUID; u public.users%ROWTYPE; request JSONB:=jsonb_build_object('target',p_target,'reason',p_reason_code);
BEGIN
 PERFORM private.require_promotion_actor(true);
 PERFORM 1 FROM private.promotion_control WHERE enabled FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'promotion_approvals_disabled'; END IF;
 result:=private.admin_operation_existing(actor,p_operation,'promotion.request',request);
 IF result IS NOT NULL THEN RETURN result; END IF;
 IF p_target IS NULL OR p_target=actor OR p_reason_code IS NULL OR p_reason_code NOT IN ('operational_coverage','succession','security_oversight') THEN RAISE EXCEPTION 'invalid_input'; END IF;
 IF NOT public.claim_rate_limit('promotion_request',3600,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 PERFORM 1 FROM public.users WHERE user_id IN (actor,p_target) ORDER BY user_id FOR UPDATE;
 PERFORM private.require_promotion_actor(true);
 SELECT * INTO u FROM public.users WHERE user_id=p_target;
 IF NOT FOUND OR u.user_role::TEXT NOT IN ('admin','moderator','support','analyst','read_only_auditor') OR u.account_status::TEXT IS DISTINCT FROM 'active' OR u.deactivated_at IS NOT NULL THEN RAISE EXCEPTION 'promotion_target_ineligible'; END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.users WHERE id=p_target AND email_confirmed_at IS NOT NULL AND (raw_app_meta_data->>'staff_invite_pending') IS DISTINCT FROM 'true')
 OR NOT EXISTS(SELECT 1 FROM auth.mfa_factors WHERE user_id=p_target AND status='verified') THEN RAISE EXCEPTION 'promotion_target_not_ready'; END IF;
 INSERT INTO private.staff_promotion_approvals(target_id,requested_by,target_role,target_revision,requester_revision,reason_code)
 VALUES(p_target,actor,u.user_role::TEXT,COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=p_target),0),
 COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=actor),0),p_reason_code) RETURNING approval_id INTO result;
 INSERT INTO private.staff_promotion_events(approval_id,actor_id,kind,version) VALUES(result,actor,'requested',1);
 PERFORM private.record_admin_operation(actor,p_operation,'promotion.request',request,result);
 PERFORM private.record_operational_audit(actor,'staff_promotion_requested','staff_promotion',result,'staff promotion','Requested independent review.',jsonb_build_object('reason_code',p_reason_code));
 RETURN result;
END $$;

CREATE FUNCTION public.admin_staff_promotion_command(p_operation UUID,p_approval UUID,p_version BIGINT,p_command TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); a private.staff_promotion_approvals%ROWTYPE; request JSONB:=jsonb_build_object('approval',p_approval,'version',p_version,'command',p_command);
BEGIN
 PERFORM private.require_promotion_actor(true);
 PERFORM 1 FROM private.promotion_control WHERE enabled FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'promotion_approvals_disabled'; END IF;
 IF p_version IS NULL OR p_version<1 OR p_command IS NULL OR p_command NOT IN ('approve','reject','cancel','execute') THEN RAISE EXCEPTION 'invalid_input'; END IF;
 IF private.admin_operation_existing(actor,p_operation,'promotion.command',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('promotion_command',60,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 SELECT * INTO a FROM private.staff_promotion_approvals WHERE approval_id=p_approval FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
 IF a.version<>p_version OR a.state NOT IN ('pending','approved') THEN RAISE EXCEPTION 'promotion_conflict'; END IF;
 PERFORM 1 FROM public.users WHERE user_id IN (actor,a.target_id,a.requested_by,a.approved_by) ORDER BY user_id FOR UPDATE;
 PERFORM private.require_promotion_actor(true);
 IF p_command='cancel' THEN
   UPDATE private.staff_promotion_approvals SET state='cancelled',version=version+1 WHERE approval_id=p_approval;
 ELSIF p_command='reject' THEN
   IF actor IN (a.requested_by,a.target_id) THEN RAISE EXCEPTION 'independent_approver_required'; END IF;
   IF a.state<>'pending' THEN RAISE EXCEPTION 'promotion_conflict'; END IF;
   UPDATE private.staff_promotion_approvals SET state='rejected',version=version+1 WHERE approval_id=p_approval;
 ELSE
   IF a.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'promotion_expired'; END IF;
   IF NOT public.is_staff(a.requested_by,ARRAY['super_admin']) OR COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=a.requested_by),0)<>a.requester_revision THEN RAISE EXCEPTION 'promotion_authority_changed'; END IF;
   IF NOT EXISTS(SELECT 1 FROM public.users WHERE user_id=a.target_id AND user_role::TEXT=a.target_role AND account_status='active' AND deactivated_at IS NULL)
      OR COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=a.target_id),0)<>a.target_revision THEN RAISE EXCEPTION 'promotion_target_changed'; END IF;
   IF p_command='approve' THEN
     IF actor IN (a.requested_by,a.target_id) THEN RAISE EXCEPTION 'independent_approver_required'; END IF;
     IF a.state<>'pending' THEN RAISE EXCEPTION 'promotion_conflict'; END IF;
     UPDATE private.staff_promotion_approvals SET state='approved',approved_by=actor,approved_at=clock_timestamp(),
       approver_revision=COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=actor),0),version=version+1 WHERE approval_id=p_approval;
   ELSE
     IF actor<>a.requested_by OR a.state<>'approved' OR a.approved_by IS NULL THEN RAISE EXCEPTION 'promotion_not_executable'; END IF;
     IF NOT public.is_staff(a.approved_by,ARRAY['super_admin']) OR COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=a.approved_by),0)<>a.approver_revision THEN RAISE EXCEPTION 'promotion_authority_changed'; END IF;
     IF NOT EXISTS(SELECT 1 FROM auth.users WHERE id=a.target_id AND email_confirmed_at IS NOT NULL AND (raw_app_meta_data->>'staff_invite_pending') IS DISTINCT FROM 'true')
     OR NOT EXISTS(SELECT 1 FROM auth.mfa_factors WHERE user_id=a.target_id AND status='verified') THEN RAISE EXCEPTION 'promotion_target_not_ready'; END IF;
     INSERT INTO private.staff_promotion_permits VALUES(txid_current(),a.target_id,actor,p_approval);
     PERFORM public.admin_set_user_role(a.target_id,'super_admin','Approved staff promotion: '||a.reason_code);
     DELETE FROM private.staff_promotion_permits WHERE transaction_id=txid_current() AND target_id=a.target_id;
     UPDATE private.staff_promotion_approvals SET state='executed',executed_at=clock_timestamp(),version=version+1 WHERE approval_id=p_approval;
   END IF;
 END IF;
 INSERT INTO private.staff_promotion_events(approval_id,actor_id,kind,version) VALUES(p_approval,actor,p_command,a.version+1);
 PERFORM private.record_admin_operation(actor,p_operation,'promotion.command',request,p_approval);
 PERFORM private.record_operational_audit(actor,'staff_promotion_'||p_command,'staff_promotion',p_approval,'staff promotion','Processed a scoped promotion approval.',jsonb_build_object('previous_version',a.version));
END $$;

CREATE FUNCTION public.admin_staff_promotion_register(p_before_at TIMESTAMPTZ DEFAULT NULL,p_before_id UUID DEFAULT NULL,p_source UUID DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM private.require_promotion_actor();
 IF NOT public.claim_rate_limit('promotion_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF NOT EXISTS(SELECT 1 FROM private.promotion_control WHERE enabled) THEN RETURN jsonb_build_object('enabled',false); END IF;
 IF (p_before_at IS NULL)<>(p_before_id IS NULL) OR (p_source IS NOT NULL AND p_before_at IS NOT NULL) OR (p_before_at IS NOT NULL AND NOT isfinite(p_before_at)) THEN RAISE EXCEPTION 'invalid_cursor'; END IF;
 RETURN jsonb_build_object('enabled',true,'measured_at',now(),'items',(SELECT COALESCE(jsonb_agg(to_jsonb(x)),'[]'::JSONB) FROM (
 SELECT a.approval_id,a.target_role,a.reason_code,a.state,a.version,a.created_at,a.expires_at,a.approved_at,a.executed_at,
 COALESCE(t.display_name,'Unavailable staff') AS target_name,COALESCE(r.display_name,'Former staff') AS requester_name,
 s.display_name AS approver_name,a.expires_at<=now() AS expired,a.requested_by=auth.uid() AS requested_by_me,
 a.target_id=auth.uid() AS targets_me
 FROM private.staff_promotion_approvals a LEFT JOIN public.users t ON t.user_id=a.target_id LEFT JOIN public.users r ON r.user_id=a.requested_by LEFT JOIN public.users s ON s.user_id=a.approved_by
 WHERE (p_source IS NULL OR a.approval_id=p_source) AND (p_before_at IS NULL OR (a.created_at,a.approval_id)<(p_before_at,p_before_id))
 ORDER BY a.created_at DESC,a.approval_id DESC LIMIT 26)x));
END $$;
CREATE FUNCTION public.admin_staff_promotion_candidates(p_query TEXT DEFAULT '') RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM private.require_promotion_actor();
 IF NOT EXISTS(SELECT 1 FROM private.promotion_control WHERE enabled) THEN RAISE EXCEPTION 'promotion_approvals_disabled'; END IF;
 IF p_query IS NULL OR length(p_query)>50 THEN RAISE EXCEPTION 'invalid_input'; END IF;
 IF NOT public.claim_rate_limit('promotion_candidates',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 RETURN (SELECT COALESCE(jsonb_agg(to_jsonb(x)),'[]'::JSONB) FROM (
 SELECT user_id,display_name,anonymous_pseudonym AS username,user_role::TEXT AS role FROM public.users
 WHERE user_role::TEXT IN ('admin','moderator','support','analyst','read_only_auditor') AND account_status='active' AND deactivated_at IS NULL
 AND EXISTS(SELECT 1 FROM auth.users a WHERE a.id=public.users.user_id AND a.email_confirmed_at IS NOT NULL AND (a.raw_app_meta_data->>'staff_invite_pending') IS DISTINCT FROM 'true')
 AND EXISTS(SELECT 1 FROM auth.mfa_factors f WHERE f.user_id=public.users.user_id AND f.status='verified')
 AND (p_query='' OR starts_with(username_normalized,lower(p_query))) ORDER BY username_normalized,user_id LIMIT 26)x);
END $$;
REVOKE ALL ON FUNCTION public.admin_request_staff_promotion(UUID,UUID,TEXT),public.admin_staff_promotion_command(UUID,UUID,BIGINT,TEXT),public.admin_staff_promotion_register(TIMESTAMPTZ,UUID,UUID),public.admin_staff_promotion_candidates(TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_request_staff_promotion(UUID,UUID,TEXT),public.admin_staff_promotion_command(UUID,UUID,BIGINT,TEXT),public.admin_staff_promotion_register(TIMESTAMPTZ,UUID,UUID),public.admin_staff_promotion_candidates(TEXT) TO authenticated;
COMMIT;
