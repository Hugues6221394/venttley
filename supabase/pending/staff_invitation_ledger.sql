-- UNAPPLIED DRAFT. Promote with Supabase CLI and verify before enabling.
-- Requires 20261029090000_operational_governance_workflows. No email/token stored.
BEGIN;
CREATE TABLE private.staff_invitation_control(singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK(singleton),enabled BOOLEAN NOT NULL DEFAULT false);
INSERT INTO private.staff_invitation_control DEFAULT VALUES;
CREATE TABLE private.staff_invitation_attempts(
  invitation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requested_by UUID NOT NULL,
  mailbox_hmac TEXT NOT NULL UNIQUE CHECK(mailbox_hmac ~ '^[0-9a-f]{64}$'),
  username TEXT NOT NULL CHECK(username ~ '^[A-Za-z0-9_]{3,24}$'),
  username_normalized TEXT GENERATED ALWAYS AS (lower(username)) STORED UNIQUE,
  requested_role TEXT NOT NULL CHECK(requested_role IN ('admin','moderator','support','analyst','read_only_auditor')),
  state TEXT NOT NULL DEFAULT 'reserved' CHECK(state IN ('reserved','provider_accepted','access_assigned')),
  invited_user_id UUID UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  provider_accepted_at TIMESTAMPTZ,
  access_assigned_at TIMESTAMPTZ,
  grant_expires_at TIMESTAMPTZ NOT NULL DEFAULT (now()+interval '24 hours'),
  cancelled_at TIMESTAMPTZ,
  version BIGINT NOT NULL DEFAULT 1 CHECK(version>0),
  CHECK((state='reserved')=(invited_user_id IS NULL))
);
CREATE TABLE private.staff_invitation_events(
  event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  invitation_id UUID NOT NULL REFERENCES private.staff_invitation_attempts,
  actor_id UUID NOT NULL,
  stage TEXT NOT NULL CHECK(stage IN ('reserved','provider_accepted','access_assigned','reconciled','cancelled')),
  version BIGINT NOT NULL DEFAULT 1 CHECK(version>0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(invitation_id,stage,version)
);
CREATE INDEX staff_invitation_cursor ON private.staff_invitation_attempts(created_at DESC,invitation_id DESC);
ALTER TABLE private.staff_invitation_control ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.staff_invitation_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.staff_invitation_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.staff_invitation_control,private.staff_invitation_attempts,private.staff_invitation_events FROM PUBLIC,anon,authenticated;
REVOKE ALL ON SEQUENCE private.staff_invitation_events_event_id_seq FROM PUBLIC,anon,authenticated;
CREATE TRIGGER staff_invitation_events_immutable BEFORE UPDATE OR DELETE ON private.staff_invitation_events FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();

CREATE FUNCTION public.admin_configure_invitation_ledger(p_operation UUID,p_enabled BOOLEAN) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); request JSONB:=jsonb_build_object('enabled',p_enabled);
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
 PERFORM private.require_aal2();
 IF p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
 IF private.admin_operation_existing(actor,p_operation,'invitation.configure',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('invitation_configure',3600,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 UPDATE private.staff_invitation_control SET enabled=p_enabled;
 PERFORM private.record_admin_operation(actor,p_operation,'invitation.configure',request,p_operation);
 PERFORM private.record_operational_audit(actor,'invitation_ledger_configured','staff_invitation_control',NULL,'staff invitations','Changed invitation ledger availability.',request);
END $$;

CREATE FUNCTION public.admin_begin_staff_invitation(p_operation UUID,p_mailbox_hmac TEXT,p_username TEXT,p_role TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); result UUID; request JSONB:=jsonb_build_object('mailbox',p_mailbox_hmac,'username',lower(p_username),'role',p_role);
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
 PERFORM private.require_aal2();
 IF NOT EXISTS(SELECT 1 FROM private.staff_invitation_control WHERE enabled) THEN RAISE EXCEPTION 'invitation_ledger_disabled'; END IF;
 result:=private.admin_operation_existing(actor,p_operation,'invitation.begin',request);
 IF result IS NOT NULL THEN RETURN jsonb_build_object('invitation_id',result,'dispatch_allowed',false); END IF;
 IF p_mailbox_hmac IS NULL OR p_mailbox_hmac !~ '^[0-9a-f]{64}$' OR p_username IS NULL OR p_username !~ '^[A-Za-z0-9_]{3,24}$' OR p_role IS NULL OR p_role NOT IN ('admin','moderator','support','analyst','read_only_auditor') THEN RAISE EXCEPTION 'invalid_input'; END IF;
 IF NOT public.claim_rate_limit('staff_invitation_begin',3600,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 INSERT INTO private.staff_invitation_attempts(requested_by,mailbox_hmac,username,requested_role) VALUES(actor,p_mailbox_hmac,p_username,p_role)
 ON CONFLICT DO NOTHING RETURNING invitation_id INTO result;
 IF result IS NULL THEN RAISE EXCEPTION 'invitation_attempt_exists'; END IF;
 INSERT INTO private.staff_invitation_events(invitation_id,actor_id,stage) VALUES(result,actor,'reserved');
 PERFORM private.record_admin_operation(actor,p_operation,'invitation.begin',request,result);
 PERFORM private.record_operational_audit(actor,'staff_invitation_reserved','staff_invitation',result,'staff invitation','Reserved a staff invitation attempt.',jsonb_build_object('role',p_role));
 RETURN jsonb_build_object('invitation_id',result,'dispatch_allowed',true);
END $$;

CREATE FUNCTION public.admin_record_staff_invitation(p_invitation UUID,p_user UUID,p_stage TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); i private.staff_invitation_attempts%ROWTYPE; u public.users%ROWTYPE; invited TIMESTAMPTZ;
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
 PERFORM private.require_aal2();
 IF NOT EXISTS(SELECT 1 FROM private.staff_invitation_control WHERE enabled) THEN RAISE EXCEPTION 'invitation_ledger_disabled'; END IF;
 IF p_user IS NULL OR p_stage IS NULL OR p_stage NOT IN ('provider_accepted','access_assigned') THEN RAISE EXCEPTION 'invalid_input'; END IF;
 IF NOT public.claim_rate_limit('staff_invitation_record',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 SELECT * INTO i FROM private.staff_invitation_attempts WHERE invitation_id=p_invitation FOR UPDATE;
 IF NOT FOUND OR i.requested_by<>actor THEN RAISE EXCEPTION 'not_authorized'; END IF;
 IF i.cancelled_at IS NOT NULL OR i.grant_expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'invitation_grant_closed'; END IF;
 IF i.invited_user_id IS NOT NULL AND i.invited_user_id<>p_user THEN RAISE EXCEPTION 'invitation_binding_mismatch'; END IF;
 SELECT * INTO u FROM public.users WHERE user_id=p_user FOR SHARE;
 SELECT invited_at INTO invited FROM auth.users WHERE id=p_user;
 -- Bind to the immutable handle and actual Auth invitation evidence, never a
 -- caller's unsupported claim that an arbitrary member was invited.
 IF u.user_id IS NULL OR lower(u.anonymous_pseudonym)<>i.username_normalized OR invited IS NULL OR invited<i.created_at-interval '1 minute' THEN RAISE EXCEPTION 'invitation_binding_mismatch'; END IF;
 IF EXISTS(SELECT 1 FROM private.staff_invitation_events WHERE invitation_id=p_invitation AND stage=p_stage) THEN RETURN; END IF;
 IF p_stage='access_assigned' AND (i.state<>'provider_accepted' OR u.user_role::TEXT<>i.requested_role) THEN RAISE EXCEPTION 'invitation_role_not_confirmed'; END IF;
 UPDATE private.staff_invitation_attempts SET invited_user_id=p_user,state=p_stage,version=version+1,
 provider_accepted_at=COALESCE(provider_accepted_at,invited),access_assigned_at=CASE WHEN p_stage='access_assigned' THEN now() ELSE access_assigned_at END WHERE invitation_id=p_invitation;
 INSERT INTO private.staff_invitation_events(invitation_id,actor_id,stage,version) VALUES(p_invitation,actor,p_stage,i.version+1);
 PERFORM private.record_operational_audit(actor,'staff_invitation_progress','staff_invitation',p_invitation,'staff invitation','Recorded database-verified invitation progress.',jsonb_build_object('stage',p_stage));
END $$;

-- Recovery never accepts a caller-chosen account or role. Lock order is receipt,
-- invitation, profile, Auth evidence. Auth tokens/passwords are never mutated.
CREATE FUNCTION public.admin_recover_staff_invitation(p_operation UUID,p_invitation UUID,p_version BIGINT,p_command TEXT,p_reason TEXT DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); i private.staff_invitation_attempts%ROWTYPE; u public.users%ROWTYPE;
 a auth.users%ROWTYPE; request JSONB:=jsonb_build_object('invitation',p_invitation,'version',p_version,'command',p_command,'reason',p_reason);
 next_stage TEXT;
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
 PERFORM private.require_aal2();
 IF NOT EXISTS(SELECT 1 FROM private.staff_invitation_control WHERE enabled) THEN RAISE EXCEPTION 'invitation_ledger_disabled'; END IF;
 IF p_invitation IS NULL OR p_version IS NULL OR p_version<1 OR p_command IS NULL OR p_command NOT IN ('reconcile','cancel','complete_grant') THEN RAISE EXCEPTION 'invalid_input'; END IF;
 IF p_reason IS NOT NULL AND (length(btrim(p_reason))=0 OR length(p_reason)>500) THEN RAISE EXCEPTION 'invalid_input'; END IF;
 IF private.admin_operation_existing(actor,p_operation,'invitation.recover',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('staff_invitation_recover',60,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 SELECT * INTO i FROM private.staff_invitation_attempts WHERE invitation_id=p_invitation FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
 IF i.version<>p_version THEN RAISE EXCEPTION 'invitation_conflict'; END IF;
 SELECT * INTO u FROM public.users WHERE username_normalized=i.username_normalized FOR UPDATE;
 IF u.user_id IS NOT NULL AND p_command<>'cancel' THEN
   SELECT * INTO a FROM auth.users WHERE id=u.user_id FOR SHARE;
   IF a.id IS NULL OR a.invited_at IS NULL OR a.created_at IS NULL OR a.created_at<i.created_at-interval '1 minute'
      OR a.invited_at<i.created_at-interval '1 minute'
      OR (i.invited_user_id IS NOT NULL AND i.invited_user_id<>u.user_id) THEN RAISE EXCEPTION 'invitation_binding_mismatch'; END IF;
 END IF;
 IF p_command='cancel' THEN
   IF i.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'invitation_grant_closed'; END IF;
   -- Do not demote an established operator or cancel a role grant that won a race.
   IF i.state='access_assigned' OR (u.user_id IS NOT NULL AND u.user_role::TEXT IS DISTINCT FROM 'normal') THEN RAISE EXCEPTION 'invitation_access_exists'; END IF;
   UPDATE private.staff_invitation_attempts SET cancelled_at=clock_timestamp(),version=version+1 WHERE invitation_id=p_invitation;
   next_stage:='cancelled';
 ELSIF p_command='reconcile' THEN
   IF u.user_id IS NULL THEN RAISE EXCEPTION 'invitation_evidence_missing'; END IF;
   IF i.state='access_assigned' THEN RAISE EXCEPTION 'invitation_access_exists'; END IF;
   -- Bind only the account created for this attempt. No email resend, role
   -- grant or fabricated assignment event follows from a current-role match.
   UPDATE private.staff_invitation_attempts SET invited_user_id=u.user_id,state='provider_accepted',
     provider_accepted_at=COALESCE(provider_accepted_at,a.invited_at),version=version+1 WHERE invitation_id=p_invitation;
   next_stage:='reconciled';
 ELSE
   IF i.cancelled_at IS NOT NULL OR i.grant_expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'invitation_grant_closed'; END IF;
   IF i.state<>'provider_accepted' OR u.user_id IS NULL OR i.invited_user_id IS DISTINCT FROM u.user_id THEN RAISE EXCEPTION 'invitation_evidence_missing'; END IF;
   IF u.user_role::TEXT IS DISTINCT FROM 'normal' OR u.account_status::TEXT IS DISTINCT FROM 'active' OR u.deactivated_at IS NOT NULL THEN RAISE EXCEPTION 'invitation_access_exists'; END IF;
   IF a.raw_app_meta_data->>'staff_invite_pending' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'invitation_setup_not_ready'; END IF;
   -- Reuse the canonical audited role/session-revocation path inside this same
   -- transaction. Cancellation and completion serialize on the invitation row.
   PERFORM public.admin_set_user_role(u.user_id,i.requested_role,COALESCE(p_reason,'Complete tracked staff invitation.'));
   UPDATE private.staff_invitation_attempts SET state='access_assigned',access_assigned_at=clock_timestamp(),version=version+1 WHERE invitation_id=p_invitation;
   next_stage:='access_assigned';
 END IF;
 INSERT INTO private.staff_invitation_events(invitation_id,actor_id,stage,version) VALUES(p_invitation,actor,next_stage,i.version+1);
 PERFORM private.record_admin_operation(actor,p_operation,'invitation.recover',request,p_invitation);
 PERFORM private.record_operational_audit(actor,'staff_invitation_recovered','staff_invitation',p_invitation,'staff invitation',
   'Recorded a scoped invitation recovery operation.',jsonb_build_object('command',p_command,'previous_version',i.version));
END $$;

CREATE FUNCTION public.admin_staff_invitation_register(p_before_at TIMESTAMPTZ DEFAULT NULL,p_before_id UUID DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
 IF NOT public.claim_rate_limit('staff_invitation_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF NOT EXISTS(SELECT 1 FROM private.staff_invitation_control WHERE enabled) THEN RETURN jsonb_build_object('enabled',false); END IF;
 IF (p_before_at IS NULL)<>(p_before_id IS NULL) THEN RAISE EXCEPTION 'invalid_cursor'; END IF;
 RETURN jsonb_build_object('enabled',true,'measured_at',now(),'items',(SELECT COALESCE(jsonb_agg(to_jsonb(x)),'[]'::JSONB) FROM (
 SELECT i.invitation_id,i.username,i.requested_role,i.state,i.created_at,i.provider_accepted_at,i.access_assigned_at,
 i.version,i.grant_expires_at,i.cancelled_at,
 i.grant_expires_at<=now() AS grant_expired,
 COALESCE(au.raw_app_meta_data->>'staff_invite_pending'='true',false) AS setup_ready,
 COALESCE(a.display_name,'Former operator') AS requested_by_name,
 u.user_role::TEXT AS current_role,u.account_status::TEXT AS account_status,
 au.email_confirmed_at IS NOT NULL AND au.last_sign_in_at IS NOT NULL AS sign_in_observed,
 i.invited_user_id IS NOT NULL AND au.id IS NULL AS auth_record_missing
 FROM private.staff_invitation_attempts i LEFT JOIN public.users a ON a.user_id=i.requested_by
 LEFT JOIN public.users u ON u.user_id=i.invited_user_id LEFT JOIN auth.users au ON au.id=i.invited_user_id
 WHERE p_before_at IS NULL OR (i.created_at,i.invitation_id)<(p_before_at,p_before_id)
 ORDER BY i.created_at DESC,i.invitation_id DESC LIMIT 26)x));
END $$;
REVOKE ALL ON FUNCTION public.admin_configure_invitation_ledger(UUID,BOOLEAN),public.admin_begin_staff_invitation(UUID,TEXT,TEXT,TEXT),public.admin_record_staff_invitation(UUID,UUID,TEXT),public.admin_staff_invitation_register(TIMESTAMPTZ,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_configure_invitation_ledger(UUID,BOOLEAN),public.admin_begin_staff_invitation(UUID,TEXT,TEXT,TEXT),public.admin_record_staff_invitation(UUID,UUID,TEXT),public.admin_staff_invitation_register(TIMESTAMPTZ,UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_recover_staff_invitation(UUID,UUID,BIGINT,TEXT,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_recover_staff_invitation(UUID,UUID,BIGINT,TEXT,TEXT) TO authenticated;
COMMIT;
