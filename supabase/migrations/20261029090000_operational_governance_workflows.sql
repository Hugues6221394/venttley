-- Canonical operational workflows for four launch-critical Super Admin gaps:
-- support cases, legal requests/disclosure approvals, crisis playbooks, and
-- recovery drills. All storage is in the unexposed private schema. Browser
-- clients receive narrowly shaped DTOs only through actor-bound admin RPCs.

-- -------------------------------------------------------------------------
-- Shared retry and audit primitives
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.admin_operation_receipts (
  actor_id UUID NOT NULL,
  operation_id UUID NOT NULL,
  operation_kind TEXT NOT NULL CHECK (operation_kind ~ '^[a-z][a-z0-9_.]{2,79}$'),
  request_hash TEXT NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  result_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_id, operation_id, operation_kind)
);

CREATE INDEX IF NOT EXISTS admin_operation_receipts_created_idx
  ON private.admin_operation_receipts (created_at);

REVOKE ALL ON TABLE private.admin_operation_receipts FROM PUBLIC, anon, authenticated;
ALTER TABLE private.admin_operation_receipts ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION private.immutable_operational_record()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'immutable_operational_record';
END;
$$;

REVOKE ALL ON FUNCTION private.immutable_operational_record() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS admin_operation_receipts_immutable ON private.admin_operation_receipts;
CREATE TRIGGER admin_operation_receipts_immutable
BEFORE UPDATE OR DELETE ON private.admin_operation_receipts
FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();

CREATE OR REPLACE FUNCTION private.admin_operation_existing(
  p_actor UUID,
  p_operation UUID,
  p_kind TEXT,
  p_request JSONB
) RETURNS UUID
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_row private.admin_operation_receipts%ROWTYPE;
  v_hash TEXT := encode(extensions.digest(p_request::TEXT,'sha256'),'hex');
BEGIN
  IF p_actor IS NULL OR p_operation IS NULL THEN
    RAISE EXCEPTION 'operation_identity_required' USING ERRCODE='22023';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_actor::TEXT||':'||p_operation::TEXT||':'||p_kind,0)
  );
  SELECT * INTO v_row
    FROM private.admin_operation_receipts
   WHERE actor_id=p_actor AND operation_id=p_operation AND operation_kind=p_kind;
  IF FOUND AND v_row.request_hash IS DISTINCT FROM v_hash THEN
    RAISE EXCEPTION 'idempotency_payload_mismatch' USING ERRCODE='22023';
  END IF;
  RETURN v_row.result_id;
END;
$$;

CREATE OR REPLACE FUNCTION private.record_admin_operation(
  p_actor UUID,
  p_operation UUID,
  p_kind TEXT,
  p_request JSONB,
  p_result UUID
) RETURNS VOID
LANGUAGE sql
SET search_path = ''
AS $$
  INSERT INTO private.admin_operation_receipts(actor_id,operation_id,operation_kind,request_hash,result_id)
  VALUES (p_actor,p_operation,p_kind,encode(extensions.digest(p_request::TEXT,'sha256'),'hex'),p_result)
  ON CONFLICT (actor_id,operation_id,operation_kind) DO NOTHING;
$$;

CREATE OR REPLACE FUNCTION private.record_operational_audit(
  p_actor UUID,
  p_action TEXT,
  p_target_type TEXT,
  p_target UUID,
  p_label TEXT,
  p_reason TEXT,
  p_metadata JSONB DEFAULT '{}'::JSONB
) RETURNS VOID
LANGUAGE sql
SET search_path = ''
AS $$
  INSERT INTO public.audit_log(
    actor_id,actor_pseudonym,actor_role,action,target_type,target_id,target_label,reason,metadata
  )
  SELECT p_actor,u.anonymous_pseudonym,u.user_role::TEXT,p_action,p_target_type,p_target,p_label,p_reason,p_metadata
    FROM public.users u WHERE u.user_id=p_actor;
$$;

REVOKE ALL ON FUNCTION private.admin_operation_existing(UUID,UUID,TEXT,JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.record_admin_operation(UUID,UUID,TEXT,JSONB,UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.record_operational_audit(UUID,TEXT,TEXT,UUID,TEXT,TEXT,JSONB) FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- Support cases
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.support_cases (
  support_case_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_kind TEXT NOT NULL CHECK (source_kind IN ('appeal','verification','privacy','account','recovery','safety','other')),
  source_id UUID,
  member_id UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  category TEXT NOT NULL CHECK (category IN ('access','appeal_help','verification_help','privacy_request','recovery_help','safety_followup','technical','other')),
  priority TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('low','normal','high','critical')),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','assigned','waiting_member','waiting_internal','resolved','closed')),
  assigned_to UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  sla_due_at TIMESTAMPTZ NOT NULL,
  first_response_at TIMESTAMPTZ,
  resolved_at TIMESTAMPTZ,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((status IN ('resolved','closed')) = (resolved_at IS NOT NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS support_cases_source_unique_idx
  ON private.support_cases (source_kind,source_id) WHERE source_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS support_cases_queue_idx
  ON private.support_cases (status,priority,sla_due_at) WHERE status NOT IN ('resolved','closed');
CREATE INDEX IF NOT EXISTS support_cases_assignee_idx
  ON private.support_cases (assigned_to,status) WHERE assigned_to IS NOT NULL;

CREATE TABLE IF NOT EXISTS private.support_case_events (
  event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  support_case_id UUID NOT NULL REFERENCES private.support_cases(support_case_id) ON DELETE CASCADE,
  event_kind TEXT NOT NULL CHECK (event_kind IN ('opened','assigned','status_changed','priority_changed','resolved','reopened')),
  actor_id UUID NOT NULL,
  detail JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS support_case_events_case_idx
  ON private.support_case_events (support_case_id,created_at);
REVOKE ALL ON TABLE private.support_cases FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.support_case_events FROM PUBLIC, anon, authenticated;
ALTER TABLE private.support_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.support_case_events ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS support_case_events_immutable ON private.support_case_events;
CREATE TRIGGER support_case_events_immutable BEFORE UPDATE OR DELETE ON private.support_case_events
FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();

CREATE OR REPLACE FUNCTION public.admin_create_support_case(
  p_operation UUID,
  p_source_kind TEXT,
  p_source_id UUID,
  p_member UUID,
  p_category TEXT,
  p_priority TEXT DEFAULT 'normal'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor UUID := (SELECT auth.uid());
  v_case UUID;
  v_existing_case private.support_cases%ROWTYPE;
  v_request JSONB := jsonb_build_object('source_kind',p_source_kind,'source_id',p_source_id,'member',p_member,'category',p_category,'priority',p_priority);
  v_sla INTERVAL;
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','support']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
  END IF;
  PERFORM private.require_aal2();
  v_case := private.admin_operation_existing(v_actor,p_operation,'support.create',v_request);
  IF v_case IS NOT NULL THEN RETURN v_case; END IF;
  IF NOT public.claim_rate_limit('admin_support_create',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_source_kind NOT IN ('appeal','verification','privacy','account','recovery','safety','other')
     OR p_category NOT IN ('access','appeal_help','verification_help','privacy_request','recovery_help','safety_followup','technical','other')
     OR p_priority NOT IN ('low','normal','high','critical') THEN
    RAISE EXCEPTION 'invalid_support_case' USING ERRCODE='22023';
  END IF;
  IF p_member IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.users WHERE user_id=p_member) THEN
    RAISE EXCEPTION 'member_not_found' USING ERRCODE='P0002';
  END IF;
  IF p_source_id IS NOT NULL THEN
    IF p_source_kind='appeal' AND NOT EXISTS (SELECT 1 FROM public.moderation_appeals WHERE appeal_id=p_source_id) THEN
      RAISE EXCEPTION 'source_not_found' USING ERRCODE='P0002';
    ELSIF p_source_kind='verification' AND NOT EXISTS (SELECT 1 FROM public.verification_requests WHERE request_id=p_source_id) THEN
      RAISE EXCEPTION 'source_not_found' USING ERRCODE='P0002';
    ELSIF p_source_kind NOT IN ('appeal','verification') THEN
      RAISE EXCEPTION 'unsupported_source_binding' USING ERRCODE='22023';
    END IF;
  END IF;
  v_sla := CASE p_priority WHEN 'critical' THEN interval '15 minutes' WHEN 'high' THEN interval '4 hours'
            WHEN 'normal' THEN interval '24 hours' ELSE interval '72 hours' END;
  INSERT INTO private.support_cases(source_kind,source_id,member_id,category,priority,sla_due_at,created_by)
  VALUES (p_source_kind,p_source_id,p_member,p_category,p_priority,now()+v_sla,v_actor)
  ON CONFLICT (source_kind,source_id) WHERE source_id IS NOT NULL DO NOTHING
  RETURNING support_case_id INTO v_case;
  IF v_case IS NULL THEN
    SELECT * INTO v_existing_case
      FROM private.support_cases
     WHERE source_kind=p_source_kind AND source_id=p_source_id;
    IF v_existing_case.member_id IS DISTINCT FROM p_member
       OR v_existing_case.category IS DISTINCT FROM p_category
       OR v_existing_case.priority IS DISTINCT FROM p_priority THEN
      RAISE EXCEPTION 'support_source_conflict' USING ERRCODE='23505';
    END IF;
    v_case := v_existing_case.support_case_id;
    PERFORM private.record_admin_operation(v_actor,p_operation,'support.create',v_request,v_case);
    RETURN v_case;
  END IF;
  INSERT INTO private.support_case_events(support_case_id,event_kind,actor_id,detail)
  VALUES (v_case,'opened',v_actor,jsonb_build_object('category',p_category,'priority',p_priority));
  PERFORM private.record_admin_operation(v_actor,p_operation,'support.create',v_request,v_case);
  PERFORM private.record_operational_audit(v_actor,'support_case_created','support_case',v_case,p_category,
    'Opened a metadata-only support case.',jsonb_build_object('source_kind',p_source_kind,'priority',p_priority));
  RETURN v_case;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_support_case(
  p_operation UUID,
  p_case UUID,
  p_status TEXT,
  p_priority TEXT,
  p_assignee UUID DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor UUID := (SELECT auth.uid());
  v_case private.support_cases%ROWTYPE;
  v_existing UUID;
  v_request JSONB := jsonb_build_object('case',p_case,'status',p_status,'priority',p_priority,'assignee',p_assignee);
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  v_existing := private.admin_operation_existing(v_actor,p_operation,'support.update',v_request);
  IF v_existing IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('admin_support_update',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_status NOT IN ('open','assigned','waiting_member','waiting_internal','resolved','closed')
     OR p_priority NOT IN ('low','normal','high','critical') THEN RAISE EXCEPTION 'invalid_support_update' USING ERRCODE='22023'; END IF;
  SELECT * INTO v_case FROM private.support_cases WHERE support_case_id=p_case FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'support_case_not_found' USING ERRCODE='P0002'; END IF;
  IF v_case.status='closed' AND p_status<>'closed' THEN RAISE EXCEPTION 'closed_support_case' USING ERRCODE='22023'; END IF;
  IF p_status='assigned' AND p_assignee IS NULL THEN RAISE EXCEPTION 'assignee_required' USING ERRCODE='22023'; END IF;
  IF p_assignee IS NOT NULL AND NOT public.is_staff(p_assignee,ARRAY['super_admin','admin','support']) THEN
    RAISE EXCEPTION 'invalid_support_assignee' USING ERRCODE='22023';
  END IF;
  UPDATE private.support_cases SET
    status=p_status,priority=p_priority,assigned_to=p_assignee,
    resolved_at=CASE WHEN p_status IN ('resolved','closed') THEN COALESCE(resolved_at,now()) ELSE NULL END,
    updated_at=now()
  WHERE support_case_id=p_case;
  INSERT INTO private.support_case_events(support_case_id,event_kind,actor_id,detail)
  VALUES (p_case,CASE WHEN p_status IN ('resolved','closed') THEN 'resolved' WHEN v_case.status IN ('resolved','closed') THEN 'reopened' ELSE 'status_changed' END,
          v_actor,jsonb_build_object('from',v_case.status,'to',p_status,'priority',p_priority,'assigned',p_assignee IS NOT NULL));
  PERFORM private.record_admin_operation(v_actor,p_operation,'support.update',v_request,p_case);
  PERFORM private.record_operational_audit(v_actor,'support_case_updated','support_case',p_case,v_case.category,
    'Updated support workflow state.',jsonb_build_object('from',v_case.status,'to',p_status,'priority',p_priority));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_support_case_queue(p_limit INTEGER DEFAULT 100)
RETURNS TABLE (
  support_case_id UUID,source_kind TEXT,source_id UUID,member_id UUID,category TEXT,priority TEXT,status TEXT,
  assignee_id UUID,assignee_name TEXT,sla_due_at TIMESTAMPTZ,first_response_at TIMESTAMPTZ,resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ,updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT c.support_case_id,c.source_kind,c.source_id,c.member_id,c.category,c.priority,c.status,c.assigned_to,
    u.display_name,c.sla_due_at,c.first_response_at,c.resolved_at,c.created_at,c.updated_at
    FROM private.support_cases c LEFT JOIN public.users u ON u.user_id=c.assigned_to
   ORDER BY (c.status NOT IN ('resolved','closed')) DESC,c.sla_due_at ASC,c.created_at DESC
   LIMIT greatest(1,least(p_limit,200));
END;
$$;

-- -------------------------------------------------------------------------
-- Legal request and independent disclosure approval
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.legal_requests (
  legal_request_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_type TEXT NOT NULL CHECK (request_type IN ('law_enforcement','court_order','preservation','privacy_regulator','emergency','other')),
  jurisdiction TEXT NOT NULL CHECK (jurisdiction ~ '^[A-Z][A-Z0-9_-]{1,15}$'),
  external_reference_hash TEXT NOT NULL UNIQUE CHECK (external_reference_hash ~ '^[0-9a-f]{64}$'),
  scope_code TEXT NOT NULL CHECK (scope_code IN ('account_metadata','content_preservation','account_disclosure','platform_statistics','emergency_request')),
  status TEXT NOT NULL DEFAULT 'received' CHECK (status IN ('received','validating','counsel_review','awaiting_approval','approved','rejected','fulfilled','closed')),
  requester_verified BOOLEAN NOT NULL DEFAULT false,
  due_at TIMESTAMPTZ NOT NULL,
  created_by UUID NOT NULL,
  approved_by UUID,
  approved_at TIMESTAMPTZ,
  approval_reason_code TEXT CHECK (approval_reason_code IN ('valid_authority','invalid_authority','insufficient_scope','emergency_authority','withdrawn')),
  disclosure_manifest_hash TEXT CHECK (disclosure_manifest_hash IS NULL OR disclosure_manifest_hash ~ '^[0-9a-f]{64}$'),
  fulfilled_by UUID,
  fulfilled_at TIMESTAMPTZ,
  completion_receipt_hash TEXT CHECK (completion_receipt_hash IS NULL OR completion_receipt_hash ~ '^[0-9a-f]{64}$'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (approved_by IS NULL OR approved_by<>created_by),
  CHECK ((status IN ('approved','fulfilled','closed') AND approved_at IS NOT NULL) OR status NOT IN ('approved','fulfilled','closed')),
  CHECK ((status='fulfilled' AND fulfilled_at IS NOT NULL) OR status<>'fulfilled')
);

CREATE INDEX IF NOT EXISTS legal_requests_queue_idx ON private.legal_requests(status,due_at);
REVOKE ALL ON TABLE private.legal_requests FROM PUBLIC, anon, authenticated;
ALTER TABLE private.legal_requests ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS private.legal_request_events (
  event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  legal_request_id UUID NOT NULL REFERENCES private.legal_requests(legal_request_id) ON DELETE CASCADE,
  event_kind TEXT NOT NULL CHECK (event_kind IN ('received','approved','rejected','fulfilled','closed')),
  actor_id UUID NOT NULL,
  detail JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS legal_request_events_request_idx ON private.legal_request_events(legal_request_id,created_at);
REVOKE ALL ON TABLE private.legal_request_events FROM PUBLIC, anon, authenticated;
ALTER TABLE private.legal_request_events ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS legal_request_events_immutable ON private.legal_request_events;
CREATE TRIGGER legal_request_events_immutable BEFORE UPDATE OR DELETE ON private.legal_request_events
FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();

CREATE OR REPLACE FUNCTION public.admin_create_legal_request(
  p_operation UUID,p_request_type TEXT,p_jurisdiction TEXT,p_reference_hash TEXT,p_scope_code TEXT,p_due_at TIMESTAMPTZ
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor UUID := (SELECT auth.uid()); v_id UUID; v_jurisdiction TEXT := upper(btrim(p_jurisdiction));
  v_request JSONB := jsonb_build_object('type',p_request_type,'jurisdiction',upper(btrim(p_jurisdiction)),'reference_hash',lower(p_reference_hash),'scope',p_scope_code,'due_at',p_due_at);
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  v_id:=private.admin_operation_existing(v_actor,p_operation,'legal.create',v_request); IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  IF NOT public.claim_rate_limit('admin_legal_create',3600,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_request_type NOT IN ('law_enforcement','court_order','preservation','privacy_regulator','emergency','other')
     OR p_scope_code NOT IN ('account_metadata','content_preservation','account_disclosure','platform_statistics','emergency_request')
     OR v_jurisdiction !~ '^[A-Z][A-Z0-9_-]{1,15}$' OR lower(p_reference_hash) !~ '^[0-9a-f]{64}$'
     OR p_due_at IS NULL OR p_due_at<=now() THEN RAISE EXCEPTION 'invalid_legal_request' USING ERRCODE='22023'; END IF;
  INSERT INTO private.legal_requests(request_type,jurisdiction,external_reference_hash,scope_code,due_at,created_by)
  VALUES(p_request_type,v_jurisdiction,lower(p_reference_hash),p_scope_code,p_due_at,v_actor) RETURNING legal_request_id INTO v_id;
  INSERT INTO private.legal_request_events(legal_request_id,event_kind,actor_id,detail)
  VALUES(v_id,'received',v_actor,jsonb_build_object('type',p_request_type,'jurisdiction',v_jurisdiction,'scope',p_scope_code));
  PERFORM private.record_admin_operation(v_actor,p_operation,'legal.create',v_request,v_id);
  PERFORM private.record_operational_audit(v_actor,'legal_request_created','legal_request',v_id,p_request_type,
    'Registered a hashed-reference legal request.',jsonb_build_object('jurisdiction',v_jurisdiction,'scope',p_scope_code));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_decide_legal_request(
  p_operation UUID,p_request UUID,p_approve BOOLEAN,p_requester_verified BOOLEAN,p_reason_code TEXT,p_manifest_hash TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor UUID := (SELECT auth.uid()); v_row private.legal_requests%ROWTYPE; v_existing UUID;
  v_request JSONB := jsonb_build_object('request',p_request,'approve',p_approve,'verified',p_requester_verified,'reason',p_reason_code,'manifest',lower(p_manifest_hash));
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  v_existing:=private.admin_operation_existing(v_actor,p_operation,'legal.decide',v_request); IF v_existing IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('admin_legal_decide',3600,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO v_row FROM private.legal_requests WHERE legal_request_id=p_request FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'legal_request_not_found' USING ERRCODE='P0002'; END IF;
  IF v_row.status NOT IN ('received','validating','counsel_review','awaiting_approval') THEN RAISE EXCEPTION 'legal_request_already_decided' USING ERRCODE='22023'; END IF;
  IF v_row.created_by=v_actor THEN RAISE EXCEPTION 'independent_approver_required' USING ERRCODE='42501'; END IF;
  IF p_reason_code NOT IN ('valid_authority','invalid_authority','insufficient_scope','emergency_authority','withdrawn') THEN RAISE EXCEPTION 'invalid_legal_reason' USING ERRCODE='22023'; END IF;
  IF p_approve AND (NOT p_requester_verified OR lower(COALESCE(p_manifest_hash,'')) !~ '^[0-9a-f]{64}$'
                    OR p_reason_code NOT IN ('valid_authority','emergency_authority')) THEN
    RAISE EXCEPTION 'verified_request_and_manifest_required' USING ERRCODE='22023';
  END IF;
  UPDATE private.legal_requests SET status=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
    requester_verified=p_requester_verified,approved_by=v_actor,approved_at=now(),approval_reason_code=p_reason_code,
    disclosure_manifest_hash=CASE WHEN p_approve THEN lower(p_manifest_hash) ELSE NULL END,updated_at=now()
  WHERE legal_request_id=p_request;
  INSERT INTO private.legal_request_events(legal_request_id,event_kind,actor_id,detail)
  VALUES(p_request,CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,v_actor,
         jsonb_build_object('reason_code',p_reason_code,'requester_verified',p_requester_verified,'manifest_recorded',p_manifest_hash IS NOT NULL));
  PERFORM private.record_admin_operation(v_actor,p_operation,'legal.decide',v_request,p_request);
  PERFORM private.record_operational_audit(v_actor,CASE WHEN p_approve THEN 'legal_request_approved' ELSE 'legal_request_rejected' END,
    'legal_request',p_request,v_row.request_type,'Independent legal request decision.',jsonb_build_object('reason_code',p_reason_code));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_mark_legal_request_fulfilled(
  p_operation UUID,p_request UUID,p_receipt_hash TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor UUID := (SELECT auth.uid()); v_row private.legal_requests%ROWTYPE; v_existing UUID;
  v_request JSONB := jsonb_build_object('request',p_request,'receipt',lower(p_receipt_hash));
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  v_existing:=private.admin_operation_existing(v_actor,p_operation,'legal.fulfill',v_request); IF v_existing IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('admin_legal_fulfill',3600,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF lower(COALESCE(p_receipt_hash,'')) !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid_receipt_hash' USING ERRCODE='22023'; END IF;
  SELECT * INTO v_row FROM private.legal_requests WHERE legal_request_id=p_request FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'legal_request_not_found' USING ERRCODE='P0002'; END IF;
  IF v_row.status<>'approved' THEN RAISE EXCEPTION 'legal_request_not_approved' USING ERRCODE='22023'; END IF;
  UPDATE private.legal_requests SET status='fulfilled',fulfilled_by=v_actor,fulfilled_at=now(),completion_receipt_hash=lower(p_receipt_hash),updated_at=now()
   WHERE legal_request_id=p_request;
  INSERT INTO private.legal_request_events(legal_request_id,event_kind,actor_id,detail)
  VALUES(p_request,'fulfilled',v_actor,jsonb_build_object('receipt_recorded',true));
  PERFORM private.record_admin_operation(v_actor,p_operation,'legal.fulfill',v_request,p_request);
  PERFORM private.record_operational_audit(v_actor,'legal_request_fulfilled','legal_request',p_request,v_row.request_type,
    'Recorded completion evidence for an approved disclosure.',jsonb_build_object('manifest_hash',v_row.disclosure_manifest_hash));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_legal_request_queue(p_limit INTEGER DEFAULT 100)
RETURNS TABLE (
  legal_request_id UUID,request_type TEXT,jurisdiction TEXT,scope_code TEXT,status TEXT,requester_verified BOOLEAN,due_at TIMESTAMPTZ,
  created_by UUID,approved_by UUID,approved_at TIMESTAMPTZ,approval_reason_code TEXT,manifest_recorded BOOLEAN,
  fulfilled_at TIMESTAMPTZ,completion_recorded BOOLEAN,created_at TIMESTAMPTZ,updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT r.legal_request_id,r.request_type,r.jurisdiction,r.scope_code,r.status,r.requester_verified,r.due_at,
    r.created_by,r.approved_by,r.approved_at,r.approval_reason_code,r.disclosure_manifest_hash IS NOT NULL,
    r.fulfilled_at,r.completion_receipt_hash IS NOT NULL,r.created_at,r.updated_at
    FROM private.legal_requests r ORDER BY (r.status NOT IN ('rejected','fulfilled','closed')) DESC,r.due_at,r.created_at DESC
   LIMIT greatest(1,least(p_limit,200));
END;
$$;

-- -------------------------------------------------------------------------
-- Versioned crisis playbooks and operator acknowledgement
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.crisis_playbooks (
  playbook_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  region_code TEXT NOT NULL CHECK (region_code='GLOBAL' OR region_code ~ '^[A-Z]{2}(-[A-Z0-9]{1,8})?$'),
  version INTEGER NOT NULL CHECK (version>0),
  title TEXT NOT NULL CHECK (length(title) BETWEEN 3 AND 160),
  body_markdown TEXT NOT NULL CHECK (length(body_markdown) BETWEEN 50 AND 12000),
  body_hash TEXT NOT NULL CHECK (body_hash ~ '^[0-9a-f]{64}$'),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','retired')),
  created_by UUID NOT NULL,
  published_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  published_at TIMESTAMPTZ,
  retired_at TIMESTAMPTZ,
  UNIQUE(region_code,version),
  CHECK (published_by IS NULL OR published_by<>created_by)
);

CREATE UNIQUE INDEX IF NOT EXISTS crisis_playbooks_one_published_region_idx
  ON private.crisis_playbooks(region_code) WHERE status='published';
REVOKE ALL ON TABLE private.crisis_playbooks FROM PUBLIC, anon, authenticated;
ALTER TABLE private.crisis_playbooks ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS private.crisis_playbook_acknowledgements (
  playbook_id UUID NOT NULL REFERENCES private.crisis_playbooks(playbook_id) ON DELETE RESTRICT,
  staff_id UUID NOT NULL,
  body_hash TEXT NOT NULL CHECK (body_hash ~ '^[0-9a-f]{64}$'),
  acknowledged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY(playbook_id,staff_id)
);
REVOKE ALL ON TABLE private.crisis_playbook_acknowledgements FROM PUBLIC, anon, authenticated;
ALTER TABLE private.crisis_playbook_acknowledgements ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS crisis_ack_immutable ON private.crisis_playbook_acknowledgements;
CREATE TRIGGER crisis_ack_immutable BEFORE UPDATE OR DELETE ON private.crisis_playbook_acknowledgements
FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();

CREATE OR REPLACE FUNCTION private.protect_published_playbook()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_OP='DELETE' OR (OLD.status IN ('published','retired') AND (
    NEW.region_code IS DISTINCT FROM OLD.region_code OR NEW.version IS DISTINCT FROM OLD.version OR
    NEW.title IS DISTINCT FROM OLD.title OR NEW.body_markdown IS DISTINCT FROM OLD.body_markdown OR NEW.body_hash IS DISTINCT FROM OLD.body_hash
  )) THEN RAISE EXCEPTION 'published_playbook_immutable'; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.protect_published_playbook() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS crisis_playbook_immutable ON private.crisis_playbooks;
CREATE TRIGGER crisis_playbook_immutable BEFORE UPDATE OR DELETE ON private.crisis_playbooks
FOR EACH ROW EXECUTE FUNCTION private.protect_published_playbook();

CREATE OR REPLACE FUNCTION public.admin_create_crisis_playbook(
  p_operation UUID,p_region_code TEXT,p_version INTEGER,p_title TEXT,p_body_markdown TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor UUID := (SELECT auth.uid()); v_id UUID; v_region TEXT:=upper(btrim(p_region_code));
  v_hash TEXT:=encode(extensions.digest(p_body_markdown,'sha256'),'hex');
  v_request JSONB:=jsonb_build_object('region',upper(btrim(p_region_code)),'version',p_version,'title',btrim(p_title),'body_hash',encode(extensions.digest(p_body_markdown,'sha256'),'hex'));
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  v_id:=private.admin_operation_existing(v_actor,p_operation,'crisis.create',v_request); IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  IF NOT public.claim_rate_limit('admin_crisis_create',3600,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF (v_region<>'GLOBAL' AND v_region !~ '^[A-Z]{2}(-[A-Z0-9]{1,8})?$') OR p_version<1
     OR length(btrim(COALESCE(p_title,''))) NOT BETWEEN 3 AND 160 OR length(COALESCE(p_body_markdown,'')) NOT BETWEEN 50 AND 12000 THEN
    RAISE EXCEPTION 'invalid_crisis_playbook' USING ERRCODE='22023';
  END IF;
  INSERT INTO private.crisis_playbooks(region_code,version,title,body_markdown,body_hash,created_by)
  VALUES(v_region,p_version,btrim(p_title),p_body_markdown,v_hash,v_actor) RETURNING playbook_id INTO v_id;
  PERFORM private.record_admin_operation(v_actor,p_operation,'crisis.create',v_request,v_id);
  PERFORM private.record_operational_audit(v_actor,'crisis_playbook_created','crisis_playbook',v_id,btrim(p_title),
    'Created a draft crisis playbook.',jsonb_build_object('region',v_region,'version',p_version,'body_hash',v_hash));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_publish_crisis_playbook(p_operation UUID,p_playbook UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor UUID:=(SELECT auth.uid()); v_row private.crisis_playbooks%ROWTYPE; v_existing UUID;
  v_request JSONB:=jsonb_build_object('playbook',p_playbook);
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  v_existing:=private.admin_operation_existing(v_actor,p_operation,'crisis.publish',v_request); IF v_existing IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('admin_crisis_publish',3600,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO v_row FROM private.crisis_playbooks WHERE playbook_id=p_playbook FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'playbook_not_found' USING ERRCODE='P0002'; END IF;
  IF v_row.status<>'draft' THEN RAISE EXCEPTION 'playbook_not_draft' USING ERRCODE='22023'; END IF;
  IF v_row.created_by=v_actor THEN RAISE EXCEPTION 'independent_publisher_required' USING ERRCODE='42501'; END IF;
  UPDATE private.crisis_playbooks SET status='retired',retired_at=now()
   WHERE region_code=v_row.region_code AND status='published';
  UPDATE private.crisis_playbooks SET status='published',published_by=v_actor,published_at=now() WHERE playbook_id=p_playbook;
  PERFORM private.record_admin_operation(v_actor,p_operation,'crisis.publish',v_request,p_playbook);
  PERFORM private.record_operational_audit(v_actor,'crisis_playbook_published','crisis_playbook',p_playbook,v_row.title,
    'Independently published a versioned crisis playbook.',jsonb_build_object('region',v_row.region_code,'version',v_row.version,'body_hash',v_row.body_hash));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_ack_crisis_playbook(p_operation UUID,p_playbook UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor UUID:=(SELECT auth.uid()); v_row private.crisis_playbooks%ROWTYPE; v_existing UUID;
  v_request JSONB:=jsonb_build_object('playbook',p_playbook);
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','moderator','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  v_existing:=private.admin_operation_existing(v_actor,p_operation,'crisis.ack',v_request); IF v_existing IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('admin_crisis_ack',60,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO v_row FROM private.crisis_playbooks WHERE playbook_id=p_playbook;
  IF NOT FOUND OR v_row.status<>'published' THEN RAISE EXCEPTION 'published_playbook_not_found' USING ERRCODE='P0002'; END IF;
  IF EXISTS(SELECT 1 FROM private.crisis_playbook_acknowledgements WHERE playbook_id=p_playbook AND staff_id=v_actor) THEN
    PERFORM private.record_admin_operation(v_actor,p_operation,'crisis.ack',v_request,p_playbook);
    RETURN;
  END IF;
  INSERT INTO private.crisis_playbook_acknowledgements(playbook_id,staff_id,body_hash)
  VALUES(p_playbook,v_actor,v_row.body_hash) ON CONFLICT DO NOTHING;
  PERFORM private.record_admin_operation(v_actor,p_operation,'crisis.ack',v_request,p_playbook);
  PERFORM private.record_operational_audit(v_actor,'crisis_playbook_acknowledged','crisis_playbook',p_playbook,v_row.title,
    'Acknowledged the exact published playbook hash.',jsonb_build_object('body_hash',v_row.body_hash));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_crisis_playbooks(p_limit INTEGER DEFAULT 50)
RETURNS TABLE(playbook_id UUID,region_code TEXT,version INTEGER,title TEXT,body_markdown TEXT,body_hash TEXT,status TEXT,
  created_by UUID,published_by UUID,created_at TIMESTAMPTZ,published_at TIMESTAMPTZ,acknowledgement_count BIGINT,acknowledged_by_me BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
DECLARE v_actor UUID:=(SELECT auth.uid());
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','moderator','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT p.playbook_id,p.region_code,p.version,p.title,p.body_markdown,p.body_hash,p.status,p.created_by,p.published_by,p.created_at,p.published_at,
    (SELECT count(*) FROM private.crisis_playbook_acknowledgements a WHERE a.playbook_id=p.playbook_id),
    EXISTS(SELECT 1 FROM private.crisis_playbook_acknowledgements a WHERE a.playbook_id=p.playbook_id AND a.staff_id=v_actor)
    FROM private.crisis_playbooks p ORDER BY (p.status='published') DESC,p.region_code,p.version DESC
   LIMIT greatest(1,least(p_limit,100));
END;
$$;

-- -------------------------------------------------------------------------
-- Independently verified recovery drills
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.recovery_drills (
  recovery_drill_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  environment TEXT NOT NULL CHECK (environment IN ('staging','isolated_restore','production_recovery_test')),
  status TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','running','passed','failed','verified','cancelled')),
  scheduled_at TIMESTAMPTZ NOT NULL,
  expected_rpo_minutes INTEGER NOT NULL CHECK (expected_rpo_minutes BETWEEN 0 AND 10080),
  expected_rto_minutes INTEGER NOT NULL CHECK (expected_rto_minutes BETWEEN 1 AND 10080),
  actual_rpo_minutes INTEGER CHECK (actual_rpo_minutes BETWEEN 0 AND 10080),
  actual_rto_minutes INTEGER CHECK (actual_rto_minutes BETWEEN 0 AND 10080),
  integrity_checks_passed INTEGER CHECK (integrity_checks_passed>=0),
  integrity_checks_total INTEGER CHECK (integrity_checks_total>=0),
  evidence_hash TEXT CHECK (evidence_hash IS NULL OR evidence_hash ~ '^[0-9a-f]{64}$'),
  created_by UUID NOT NULL,
  completed_by UUID,
  verified_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  verified_at TIMESTAMPTZ,
  CHECK (verified_by IS NULL OR verified_by<>completed_by),
  CHECK (integrity_checks_passed IS NULL OR integrity_checks_total IS NULL OR integrity_checks_passed<=integrity_checks_total)
);
CREATE INDEX IF NOT EXISTS recovery_drills_schedule_idx ON private.recovery_drills(status,scheduled_at DESC);
REVOKE ALL ON TABLE private.recovery_drills FROM PUBLIC, anon, authenticated;
ALTER TABLE private.recovery_drills ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.admin_create_recovery_drill(
  p_operation UUID,p_environment TEXT,p_scheduled_at TIMESTAMPTZ,p_expected_rpo_minutes INTEGER,p_expected_rto_minutes INTEGER
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor UUID:=(SELECT auth.uid()); v_id UUID;
  v_request JSONB:=jsonb_build_object('environment',p_environment,'scheduled_at',p_scheduled_at,'rpo',p_expected_rpo_minutes,'rto',p_expected_rto_minutes);
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  v_id:=private.admin_operation_existing(v_actor,p_operation,'recovery.create',v_request); IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  IF NOT public.claim_rate_limit('admin_recovery_create',3600,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_environment NOT IN ('staging','isolated_restore','production_recovery_test') OR p_scheduled_at IS NULL
     OR p_expected_rpo_minutes NOT BETWEEN 0 AND 10080 OR p_expected_rto_minutes NOT BETWEEN 1 AND 10080 THEN
    RAISE EXCEPTION 'invalid_recovery_drill' USING ERRCODE='22023';
  END IF;
  INSERT INTO private.recovery_drills(environment,scheduled_at,expected_rpo_minutes,expected_rto_minutes,created_by)
  VALUES(p_environment,p_scheduled_at,p_expected_rpo_minutes,p_expected_rto_minutes,v_actor) RETURNING recovery_drill_id INTO v_id;
  PERFORM private.record_admin_operation(v_actor,p_operation,'recovery.create',v_request,v_id);
  PERFORM private.record_operational_audit(v_actor,'recovery_drill_scheduled','recovery_drill',v_id,p_environment,
    'Scheduled a recovery drill.',jsonb_build_object('expected_rpo_minutes',p_expected_rpo_minutes,'expected_rto_minutes',p_expected_rto_minutes));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_complete_recovery_drill(
  p_operation UUID,p_drill UUID,p_passed BOOLEAN,p_actual_rpo_minutes INTEGER,p_actual_rto_minutes INTEGER,
  p_checks_passed INTEGER,p_checks_total INTEGER,p_evidence_hash TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor UUID:=(SELECT auth.uid()); v_row private.recovery_drills%ROWTYPE; v_existing UUID;
  v_request JSONB:=jsonb_build_object('drill',p_drill,'passed',p_passed,'rpo',p_actual_rpo_minutes,'rto',p_actual_rto_minutes,'checks_passed',p_checks_passed,'checks_total',p_checks_total,'evidence',lower(p_evidence_hash));
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  v_existing:=private.admin_operation_existing(v_actor,p_operation,'recovery.complete',v_request); IF v_existing IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('admin_recovery_complete',3600,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_actual_rpo_minutes NOT BETWEEN 0 AND 10080 OR p_actual_rto_minutes NOT BETWEEN 0 AND 10080 OR p_checks_passed<0 OR p_checks_total<1
     OR p_checks_passed>p_checks_total OR lower(COALESCE(p_evidence_hash,'')) !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_recovery_evidence' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_row FROM private.recovery_drills WHERE recovery_drill_id=p_drill FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'recovery_drill_not_found' USING ERRCODE='P0002'; END IF;
  IF v_row.status NOT IN ('scheduled','running') THEN RAISE EXCEPTION 'recovery_drill_not_completable' USING ERRCODE='22023'; END IF;
  UPDATE private.recovery_drills SET status=CASE WHEN p_passed THEN 'passed' ELSE 'failed' END,
    actual_rpo_minutes=p_actual_rpo_minutes,actual_rto_minutes=p_actual_rto_minutes,
    integrity_checks_passed=p_checks_passed,integrity_checks_total=p_checks_total,evidence_hash=lower(p_evidence_hash),
    completed_by=v_actor,completed_at=now() WHERE recovery_drill_id=p_drill;
  PERFORM private.record_admin_operation(v_actor,p_operation,'recovery.complete',v_request,p_drill);
  PERFORM private.record_operational_audit(v_actor,'recovery_drill_completed','recovery_drill',p_drill,v_row.environment,
    'Recorded recovery drill results.',jsonb_build_object('passed',p_passed,'actual_rpo_minutes',p_actual_rpo_minutes,'actual_rto_minutes',p_actual_rto_minutes,'evidence_hash',lower(p_evidence_hash)));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_verify_recovery_drill(p_operation UUID,p_drill UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor UUID:=(SELECT auth.uid()); v_row private.recovery_drills%ROWTYPE; v_existing UUID;
  v_request JSONB:=jsonb_build_object('drill',p_drill);
BEGIN
  IF NOT public.is_staff(v_actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  v_existing:=private.admin_operation_existing(v_actor,p_operation,'recovery.verify',v_request); IF v_existing IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('admin_recovery_verify',3600,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO v_row FROM private.recovery_drills WHERE recovery_drill_id=p_drill FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'recovery_drill_not_found' USING ERRCODE='P0002'; END IF;
  IF v_row.status NOT IN ('passed','failed') OR v_row.evidence_hash IS NULL THEN RAISE EXCEPTION 'recovery_evidence_not_ready' USING ERRCODE='22023'; END IF;
  IF v_row.completed_by=v_actor THEN RAISE EXCEPTION 'independent_verifier_required' USING ERRCODE='42501'; END IF;
  UPDATE private.recovery_drills SET status='verified',verified_by=v_actor,verified_at=now() WHERE recovery_drill_id=p_drill;
  PERFORM private.record_admin_operation(v_actor,p_operation,'recovery.verify',v_request,p_drill);
  PERFORM private.record_operational_audit(v_actor,'recovery_drill_verified','recovery_drill',p_drill,v_row.environment,
    'Independently verified recovery drill evidence.',jsonb_build_object('evidence_hash',v_row.evidence_hash,'result',v_row.status));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_recovery_drills(p_limit INTEGER DEFAULT 50)
RETURNS TABLE(recovery_drill_id UUID,environment TEXT,status TEXT,scheduled_at TIMESTAMPTZ,expected_rpo_minutes INTEGER,expected_rto_minutes INTEGER,
  actual_rpo_minutes INTEGER,actual_rto_minutes INTEGER,checks_passed INTEGER,checks_total INTEGER,evidence_recorded BOOLEAN,
  created_by UUID,completed_by UUID,verified_by UUID,completed_at TIMESTAMPTZ,verified_at TIMESTAMPTZ,created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = '' AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT d.recovery_drill_id,d.environment,d.status,d.scheduled_at,d.expected_rpo_minutes,d.expected_rto_minutes,
    d.actual_rpo_minutes,d.actual_rto_minutes,d.integrity_checks_passed,d.integrity_checks_total,d.evidence_hash IS NOT NULL,
    d.created_by,d.completed_by,d.verified_by,d.completed_at,d.verified_at,d.created_at
    FROM private.recovery_drills d ORDER BY d.scheduled_at DESC LIMIT greatest(1,least(p_limit,100));
END;
$$;

-- Preserve the original aggregate snapshot for compatibility, but correct
-- capability flags that this migration has actually made true. External
-- disclosure delivery and automated restore proof deliberately remain false.
DO $$
BEGIN
  IF pg_catalog.to_regprocedure('public.admin_control_plane_snapshot_v1(text)') IS NULL THEN
    ALTER FUNCTION public.admin_control_plane_snapshot(TEXT) RENAME TO admin_control_plane_snapshot_v1;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_control_plane_snapshot_v1(TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_control_plane_snapshot(p_section TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
DECLARE
  v_actor UUID := (SELECT auth.uid());
  v_snapshot JSONB;
BEGIN
  IF p_section NOT IN (
    'campaigns','support_cases','legal_requests','crisis_playbooks',
    'recovery_readiness','moderation_workforce','model_operations',
    'messaging_operations','storage_operations','regional_compliance',
    'transparency_reports','experiments'
  ) THEN
    RAISE EXCEPTION 'unknown_control_section' USING ERRCODE='22023';
  END IF;
  -- Keep authorization visible at this public boundary as well as in the
  -- delegated v1 implementation. The delegated function applies the narrower
  -- per-section role matrix.
  IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
  END IF;
  v_snapshot := public.admin_control_plane_snapshot_v1(p_section);
  IF p_section='support_cases' THEN
    v_snapshot := jsonb_set(v_snapshot,'{data,dedicated_support_case_entity_available}','true'::JSONB,true);
    v_snapshot := jsonb_set(v_snapshot,'{data,canonical_cases}',to_jsonb((SELECT count(*) FROM private.support_cases)),true);
  ELSIF p_section='legal_requests' THEN
    v_snapshot := jsonb_set(v_snapshot,'{data,legal_request_entity_available}','true'::JSONB,true);
    v_snapshot := jsonb_set(v_snapshot,'{data,canonical_requests}',to_jsonb((SELECT count(*) FROM private.legal_requests)),true);
  ELSIF p_section='crisis_playbooks' THEN
    v_snapshot := jsonb_set(v_snapshot,'{data,playbook_acknowledgement_available}','true'::JSONB,true);
    v_snapshot := jsonb_set(v_snapshot,'{data,published_playbooks}',to_jsonb((SELECT count(*) FROM private.crisis_playbooks WHERE status='published')),true);
  ELSIF p_section='recovery_readiness' THEN
    v_snapshot := jsonb_set(v_snapshot,'{data,recovery_drill_register_available}','true'::JSONB,true);
    v_snapshot := jsonb_set(v_snapshot,'{data,verified_recovery_drills}',to_jsonb((SELECT count(*) FROM private.recovery_drills WHERE status='verified')),true);
  END IF;
  RETURN v_snapshot;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_control_plane_snapshot(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_control_plane_snapshot(TEXT) TO authenticated;

-- Explicit function ACLs. SECURITY DEFINER functions otherwise inherit
-- EXECUTE for PUBLIC at creation time.
REVOKE ALL ON FUNCTION public.admin_create_support_case(UUID,TEXT,UUID,UUID,TEXT,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_update_support_case(UUID,UUID,TEXT,TEXT,UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_support_case_queue(INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_create_legal_request(UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_decide_legal_request(UUID,UUID,BOOLEAN,BOOLEAN,TEXT,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_mark_legal_request_fulfilled(UUID,UUID,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_legal_request_queue(INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_create_crisis_playbook(UUID,TEXT,INTEGER,TEXT,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_publish_crisis_playbook(UUID,UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_ack_crisis_playbook(UUID,UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_crisis_playbooks(INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_create_recovery_drill(UUID,TEXT,TIMESTAMPTZ,INTEGER,INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_complete_recovery_drill(UUID,UUID,BOOLEAN,INTEGER,INTEGER,INTEGER,INTEGER,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_verify_recovery_drill(UUID,UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_recovery_drills(INTEGER) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_create_support_case(UUID,TEXT,UUID,UUID,TEXT,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_support_case(UUID,UUID,TEXT,TEXT,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_support_case_queue(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_legal_request(UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_decide_legal_request(UUID,UUID,BOOLEAN,BOOLEAN,TEXT,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_mark_legal_request_fulfilled(UUID,UUID,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_legal_request_queue(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_crisis_playbook(UUID,TEXT,INTEGER,TEXT,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_publish_crisis_playbook(UUID,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_ack_crisis_playbook(UUID,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_crisis_playbooks(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_recovery_drill(UUID,TEXT,TIMESTAMPTZ,INTEGER,INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_complete_recovery_drill(UUID,UUID,BOOLEAN,INTEGER,INTEGER,INTEGER,INTEGER,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_verify_recovery_drill(UUID,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_recovery_drills(INTEGER) TO authenticated;

-- The ledger, so a database can say whether it has run this.
SELECT public.record_migration('20261029090000', 'operational_governance_workflows');

NOTIFY pgrst, 'reload schema';
