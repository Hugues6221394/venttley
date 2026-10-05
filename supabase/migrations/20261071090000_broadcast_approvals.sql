-- Two-person approval for global broadcasts. Ships disabled (broadcast_approval_control).
-- Depends on operational governance receipts and 20261070090000_staff_promotion_approvals
-- (authority revisions). No scheduling, targeted audiences or push delivery.
BEGIN;
CREATE TABLE private.broadcast_approval_control (
 singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK(singleton), enabled BOOLEAN NOT NULL DEFAULT false
);
INSERT INTO private.broadcast_approval_control DEFAULT VALUES;
CREATE TABLE private.broadcast_approval_controls (
 operation_id UUID PRIMARY KEY, enabled BOOLEAN NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE private.broadcast_approvals (
 approval_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), requested_by UUID NOT NULL,
 requester_revision BIGINT NOT NULL, title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 120),
 body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 1000),
 urgency TEXT NOT NULL CHECK(urgency IN ('info','warning','critical','crisis')),
 publication_expires_at TIMESTAMPTZ NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','approved','rejected','cancelled','published')),
 approved_by UUID, approver_revision BIGINT, approved_at TIMESTAMPTZ, published_at TIMESTAMPTZ,
 broadcast_id UUID UNIQUE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 expires_at TIMESTAMPTZ NOT NULL DEFAULT (now()+interval '24 hours'), version BIGINT NOT NULL DEFAULT 1,
 CHECK(version>0), CHECK(approved_by IS NULL OR approved_by<>requested_by)
);
CREATE INDEX broadcast_approvals_cursor ON private.broadcast_approvals(created_at DESC,approval_id DESC);
CREATE TABLE private.broadcast_approval_events (
 event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 approval_id UUID NOT NULL REFERENCES private.broadcast_approvals, actor_id UUID NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('requested','approve','reject','cancel','publish')),
 version BIGINT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), UNIQUE(approval_id,version)
);
CREATE TABLE private.broadcast_approval_permits (
 transaction_id BIGINT PRIMARY KEY, approval_id UUID NOT NULL REFERENCES private.broadcast_approvals,
 actor_id UUID NOT NULL, broadcast_id UUID NOT NULL
);
ALTER TABLE private.broadcast_approval_control ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.broadcast_approval_controls ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.broadcast_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.broadcast_approval_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.broadcast_approval_permits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.broadcast_approval_control,private.broadcast_approval_controls,private.broadcast_approvals,
 private.broadcast_approval_events,private.broadcast_approval_permits FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON SEQUENCE private.broadcast_approval_events_event_id_seq FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER broadcast_controls_immutable BEFORE UPDATE OR DELETE ON private.broadcast_approval_controls
 FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();
CREATE TRIGGER broadcast_events_immutable BEFORE UPDATE OR DELETE ON private.broadcast_approval_events
 FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();

CREATE FUNCTION public.service_configure_broadcast_approvals(p_operation UUID,p_enabled BOOLEAN) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
 UPDATE private.broadcast_approval_control SET enabled=p_enabled;
 INSERT INTO private.broadcast_approval_controls(operation_id,enabled) VALUES(p_operation,p_enabled);
END $$;
REVOKE ALL ON FUNCTION public.service_configure_broadcast_approvals(UUID,BOOLEAN) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.service_configure_broadcast_approvals(UUID,BOOLEAN) TO service_role;

CREATE FUNCTION private.require_broadcast_actor(p_mutation BOOLEAN DEFAULT false) RETURNS VOID
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.sessions WHERE id=private.current_auth_session_id() AND user_id=auth.uid()
   AND (not_after IS NULL OR not_after>clock_timestamp()) AND (NOT p_mutation OR aal::TEXT='aal2')) THEN
   RAISE EXCEPTION 'broadcast_session_unavailable';
 END IF;
 IF p_mutation THEN PERFORM private.require_aal2(); END IF;
END $$;

-- Approval content is immutable. Changing any field requires a new request.
CREATE FUNCTION private.freeze_broadcast_approval_payload() RETURNS TRIGGER LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF (NEW.approval_id,NEW.requested_by,NEW.requester_revision,NEW.title,NEW.body,NEW.urgency,NEW.publication_expires_at,NEW.created_at,NEW.expires_at)
 IS DISTINCT FROM (OLD.approval_id,OLD.requested_by,OLD.requester_revision,OLD.title,OLD.body,OLD.urgency,OLD.publication_expires_at,OLD.created_at,OLD.expires_at)
 THEN RAISE EXCEPTION 'broadcast_payload_immutable'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER freeze_broadcast_approval_payload BEFORE UPDATE ON private.broadcast_approvals
 FOR EACH ROW EXECUTE FUNCTION private.freeze_broadcast_approval_payload();

-- Protect legacy RPCs/direct writers as well as the new UI. Deactivation and
-- counter updates remain available. Reactivation and message edits do not.
CREATE FUNCTION private.enforce_broadcast_approval() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM 1 FROM private.broadcast_approval_control WHERE enabled FOR SHARE;
 IF NOT FOUND THEN RETURN NEW; END IF;
 IF TG_OP='UPDATE' THEN
   IF (to_jsonb(NEW)-ARRAY['is_active','delivered_count','dismissed_count']) = (to_jsonb(OLD)-ARRAY['is_active','delivered_count','dismissed_count'])
   AND (NEW.is_active=OLD.is_active OR NEW.is_active=false) THEN RETURN NEW; END IF;
   RAISE EXCEPTION 'broadcast_approval_required';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM private.broadcast_approval_permits p JOIN private.broadcast_approvals a USING(approval_id)
   WHERE p.transaction_id=txid_current() AND p.actor_id=auth.uid() AND p.broadcast_id=NEW.broadcast_id
   AND a.requested_by=auth.uid() AND a.state='approved' AND a.expires_at>clock_timestamp()
   AND a.publication_expires_at>clock_timestamp() AND NEW.title=a.title AND NEW.body=a.body AND NEW.urgency=a.urgency
   AND NEW.audience='{"scope":"all"}'::JSONB AND NEW.scheduled_for IS NULL AND NEW.sent_at IS NOT NULL
   AND NEW.expires_at=a.publication_expires_at AND NEW.sent_by=auth.uid() AND NEW.is_active=true
   AND NEW.delivered_count=0 AND NEW.dismissed_count=0) THEN RAISE EXCEPTION 'broadcast_approval_required'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER enforce_broadcast_approval BEFORE INSERT OR UPDATE ON public.broadcasts
 FOR EACH ROW EXECUTE FUNCTION private.enforce_broadcast_approval();
REVOKE ALL ON FUNCTION private.require_broadcast_actor(BOOLEAN),private.freeze_broadcast_approval_payload(),
 private.enforce_broadcast_approval() FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.admin_request_broadcast_approval(p_operation UUID,p_title TEXT,p_body TEXT,p_urgency TEXT,p_expires_at TIMESTAMPTZ) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); result UUID;
 request JSONB:=jsonb_build_object('title',p_title,'body',p_body,'urgency',p_urgency,'expires_at',p_expires_at,'audience','all');
BEGIN
 PERFORM private.require_broadcast_actor(true);
 PERFORM 1 FROM private.broadcast_approval_control WHERE enabled FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'broadcast_approvals_disabled'; END IF;
 result:=private.admin_operation_existing(actor,p_operation,'broadcast.request',request);
 IF result IS NOT NULL THEN RETURN result; END IF;
 IF p_title IS NULL OR length(btrim(p_title)) NOT BETWEEN 1 AND 120 OR p_title<>btrim(p_title)
 OR p_body IS NULL OR length(btrim(p_body)) NOT BETWEEN 1 AND 1000 OR p_body<>btrim(p_body)
 OR p_title~'[[:cntrl:]]' OR p_body~'[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]' OR p_title~'[<>]' OR p_body~'[<>]'
 OR p_urgency IS NULL OR p_urgency NOT IN ('info','warning','critical','crisis')
 OR p_expires_at IS NULL OR p_expires_at<=clock_timestamp() OR p_expires_at>clock_timestamp()+interval '7 days'
 THEN RAISE EXCEPTION 'invalid_broadcast_payload'; END IF;
 IF NOT public.claim_rate_limit('broadcast_request',3600,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 PERFORM 1 FROM public.users WHERE user_id=actor FOR UPDATE;
 PERFORM private.require_broadcast_actor(true);
 INSERT INTO private.broadcast_approvals(requested_by,requester_revision,title,body,urgency,publication_expires_at)
 VALUES(actor,COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=actor),0),p_title,p_body,p_urgency,p_expires_at)
 RETURNING approval_id INTO result;
 INSERT INTO private.broadcast_approval_events(approval_id,actor_id,kind,version) VALUES(result,actor,'requested',1);
 PERFORM private.record_admin_operation(actor,p_operation,'broadcast.request',request,result);
 PERFORM private.record_operational_audit(actor,'broadcast_approval_requested','broadcast_approval',result,'global broadcast','Requested independent review.',jsonb_build_object('urgency',p_urgency));
 RETURN result;
END $$;

CREATE FUNCTION public.admin_broadcast_approval_command(p_operation UUID,p_approval UUID,p_version BIGINT,p_command TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); a private.broadcast_approvals%ROWTYPE; publication UUID;
 request JSONB:=jsonb_build_object('approval',p_approval,'version',p_version,'command',p_command);
BEGIN
 PERFORM private.require_broadcast_actor(true);
 PERFORM 1 FROM private.broadcast_approval_control WHERE enabled FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'broadcast_approvals_disabled'; END IF;
 IF p_version IS NULL OR p_version<1 OR p_command IS NULL OR p_command NOT IN ('approve','reject','cancel','publish') THEN RAISE EXCEPTION 'invalid_input'; END IF;
 IF private.admin_operation_existing(actor,p_operation,'broadcast.command',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('broadcast_command',60,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 SELECT * INTO a FROM private.broadcast_approvals WHERE approval_id=p_approval FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
 IF a.version<>p_version OR a.state NOT IN ('pending','approved') THEN RAISE EXCEPTION 'broadcast_conflict'; END IF;
 PERFORM 1 FROM public.users WHERE user_id IN (actor,a.requested_by,a.approved_by) ORDER BY user_id FOR UPDATE;
 PERFORM private.require_broadcast_actor(true);
 IF p_command='cancel' THEN
   IF actor<>a.requested_by AND NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
   UPDATE private.broadcast_approvals SET state='cancelled',version=version+1 WHERE approval_id=p_approval;
 ELSIF p_command='reject' THEN
   IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
   IF actor=a.requested_by THEN RAISE EXCEPTION 'independent_approver_required'; END IF;
   IF a.state<>'pending' THEN RAISE EXCEPTION 'broadcast_conflict'; END IF;
   UPDATE private.broadcast_approvals SET state='rejected',version=version+1 WHERE approval_id=p_approval;
 ELSE
   IF a.expires_at<=clock_timestamp() OR a.publication_expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'broadcast_expired'; END IF;
   IF NOT public.is_staff(a.requested_by,ARRAY['super_admin','admin']) OR COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=a.requested_by),0)<>a.requester_revision THEN RAISE EXCEPTION 'broadcast_authority_changed'; END IF;
   IF p_command='approve' THEN
     IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
     IF actor=a.requested_by THEN RAISE EXCEPTION 'independent_approver_required'; END IF;
     IF a.state<>'pending' THEN RAISE EXCEPTION 'broadcast_conflict'; END IF;
     UPDATE private.broadcast_approvals SET state='approved',approved_by=actor,approved_at=clock_timestamp(),
       approver_revision=COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=actor),0),version=version+1 WHERE approval_id=p_approval;
   ELSE
     IF actor<>a.requested_by OR a.state<>'approved' OR a.approved_by IS NULL THEN RAISE EXCEPTION 'not_authorized'; END IF;
     IF NOT public.is_staff(a.approved_by,ARRAY['super_admin']) OR COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=a.approved_by),0)<>a.approver_revision THEN RAISE EXCEPTION 'broadcast_authority_changed'; END IF;
     publication:=gen_random_uuid();
     INSERT INTO private.broadcast_approval_permits VALUES(txid_current(),p_approval,actor,publication);
     -- Same canonical publication table, not a second delivery system. Do not
     -- reuse legacy admin_send_broadcast's content-bearing audit payload.
     INSERT INTO public.broadcasts(broadcast_id,title,body,urgency,audience,sent_at,expires_at,sent_by)
     -- now(), not clock_timestamp(): the read policy compares sent_at with now().
    VALUES(publication,a.title,a.body,a.urgency,'{"scope":"all"}',now(),a.publication_expires_at,actor);
     DELETE FROM private.broadcast_approval_permits WHERE transaction_id=txid_current();
     UPDATE private.broadcast_approvals SET state='published',broadcast_id=publication,published_at=clock_timestamp(),version=version+1 WHERE approval_id=p_approval;
   END IF;
 END IF;
 INSERT INTO private.broadcast_approval_events(approval_id,actor_id,kind,version) VALUES(p_approval,actor,p_command,a.version+1);
 PERFORM private.record_admin_operation(actor,p_operation,'broadcast.command',request,p_approval);
 PERFORM private.record_operational_audit(actor,'broadcast_approval_'||p_command,'broadcast_approval',p_approval,'global broadcast','Processed scoped broadcast approval.',jsonb_build_object('previous_version',a.version,'broadcast_id',publication));
END $$;

CREATE FUNCTION public.admin_stop_approved_broadcast(p_operation UUID,p_approval UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); a private.broadcast_approvals%ROWTYPE; request JSONB:=jsonb_build_object('approval',p_approval);
BEGIN
 PERFORM private.require_broadcast_actor(true);
 -- Emergency stop remains available even if the approval control is off.
 IF private.admin_operation_existing(actor,p_operation,'broadcast.stop',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('broadcast_stop',60,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 SELECT * INTO a FROM private.broadcast_approvals WHERE approval_id=p_approval FOR UPDATE;
 IF NOT FOUND OR a.state<>'published' THEN RAISE EXCEPTION 'not_found'; END IF;
 PERFORM 1 FROM public.users WHERE user_id=actor FOR UPDATE;
 PERFORM private.require_broadcast_actor(true);
 UPDATE public.broadcasts SET is_active=false WHERE broadcast_id=a.broadcast_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
 PERFORM private.record_admin_operation(actor,p_operation,'broadcast.stop',request,p_approval);
 PERFORM private.record_operational_audit(actor,'broadcast_approval_stop','broadcast_approval',p_approval,'global broadcast','Deactivated published broadcast.',jsonb_build_object('broadcast_id',a.broadcast_id));
END $$;

CREATE FUNCTION public.admin_broadcast_approval_register(p_before_at TIMESTAMPTZ DEFAULT NULL,p_before_id UUID DEFAULT NULL,p_source UUID DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM private.require_broadcast_actor();
 IF NOT public.claim_rate_limit('broadcast_approval_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF NOT EXISTS(SELECT 1 FROM private.broadcast_approval_control WHERE enabled) THEN RETURN jsonb_build_object('enabled',false); END IF;
 IF (p_before_at IS NULL)<>(p_before_id IS NULL) OR (p_source IS NOT NULL AND p_before_at IS NOT NULL) OR (p_before_at IS NOT NULL AND NOT isfinite(p_before_at)) THEN RAISE EXCEPTION 'invalid_cursor'; END IF;
 RETURN jsonb_build_object('enabled',true,'measured_at',now(),'items',(SELECT COALESCE(jsonb_agg(to_jsonb(x)),'[]'::JSONB) FROM (
 SELECT a.approval_id,a.title,a.body,a.urgency,a.state,a.version,a.created_at,a.expires_at,a.publication_expires_at,
 a.approved_at,a.published_at,a.broadcast_id,b.is_active AS publication_active,
 COALESCE(r.display_name,'Former staff') AS requester_name,s.display_name AS approver_name,
 (a.expires_at<=now() OR a.publication_expires_at<=now()) AS expired,a.requested_by=auth.uid() AS requested_by_me
 FROM private.broadcast_approvals a LEFT JOIN public.users r ON r.user_id=a.requested_by LEFT JOIN public.users s ON s.user_id=a.approved_by
 LEFT JOIN public.broadcasts b ON b.broadcast_id=a.broadcast_id
 WHERE (p_source IS NULL OR a.approval_id=p_source) AND (p_before_at IS NULL OR (a.created_at,a.approval_id)<(p_before_at,p_before_id))
 ORDER BY a.created_at DESC,a.approval_id DESC LIMIT 26)x));
END $$;
REVOKE ALL ON FUNCTION public.admin_request_broadcast_approval(UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ),
 public.admin_broadcast_approval_command(UUID,UUID,BIGINT,TEXT),public.admin_broadcast_approval_register(TIMESTAMPTZ,UUID,UUID),
 public.admin_stop_approved_broadcast(UUID,UUID) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.admin_request_broadcast_approval(UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ),
 public.admin_broadcast_approval_command(UUID,UUID,BIGINT,TEXT),public.admin_broadcast_approval_register(TIMESTAMPTZ,UUID,UUID),
 public.admin_stop_approved_broadcast(UUID,UUID) TO authenticated;
COMMIT;

-- Every migration records itself, so the app can tell a database that is
-- behind the build from one that is current. Added after the fact: this file
-- shipped without it, and the copy already applied to production is
-- back-filled by 20261075090000_the_ledger_catches_up.sql.
SELECT public.record_migration('20261071090000', 'broadcast_approvals');
