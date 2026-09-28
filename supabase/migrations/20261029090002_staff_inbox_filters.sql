-- CLI-generated 20260924152704, ordered immediately after its existing
-- future-dated inbox foundation dependency. Additive; no rollout is enabled.
-- Filters execute BEFORE the cursor/limit. The older RPC remains compatible.
CREATE OR REPLACE FUNCTION public.admin_staff_inbox_page(
  p_filter TEXT DEFAULT 'all', p_category TEXT DEFAULT 'all', p_severity TEXT DEFAULT 'all',
  p_limit INTEGER DEFAULT 30, p_before_at TIMESTAMPTZ DEFAULT NULL, p_before_id UUID DEFAULT NULL
) RETURNS TABLE(event_id UUID,kind TEXT,severity TEXT,source_id UUID,destination TEXT,delivered_at TIMESTAMPTZ,read_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid();
BEGIN
  IF NOT public.is_staff(actor,ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF NOT public.claim_rate_limit('staff_inbox_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_filter IS NULL OR p_filter NOT IN ('all','unread','urgent','assigned')
    OR p_category IS NULL OR p_category NOT IN ('all','support','legal')
    OR p_severity IS NULL OR p_severity NOT IN ('all','info','warning','critical')
    OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
    OR ((p_before_at IS NULL)<>(p_before_id IS NULL)) THEN RAISE EXCEPTION 'invalid_inbox_query' USING ERRCODE='22023'; END IF;
  IF NOT (SELECT enabled AND public.is_staff(actor,audience_roles) FROM private.staff_inbox_control WHERE singleton) THEN RETURN; END IF;
  RETURN QUERY SELECT o.event_id,o.kind,o.severity,o.source_id,
    CASE WHEN o.kind='legal_review_requested' THEN '/legal-requests' ELSE '/support/cases' END,
    d.delivered_at,d.read_at
  FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
  WHERE d.recipient_id=actor AND private.can_read_staff_event(actor,o.kind,o.source_id)
    AND (p_filter<>'unread' OR d.read_at IS NULL)
    AND (p_filter<>'urgent' OR o.severity='critical')
    AND (p_filter<>'assigned' OR EXISTS(SELECT 1 FROM private.support_cases c WHERE c.support_case_id=o.source_id AND c.assigned_to=actor AND c.status NOT IN ('resolved','closed')))
    AND (p_category='all' OR (p_category='legal' AND o.kind='legal_review_requested') OR (p_category='support' AND o.kind IN ('support_assigned','support_sla_breached')))
    AND (p_severity='all' OR o.severity=p_severity)
    AND (p_before_at IS NULL OR (d.delivered_at,d.event_id)<(p_before_at,p_before_id))
  ORDER BY d.delivered_at DESC,d.event_id DESC LIMIT p_limit;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_staff_inbox_page(TEXT,TEXT,TEXT,INTEGER,TIMESTAMPTZ,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_staff_inbox_page(TEXT,TEXT,TEXT,INTEGER,TIMESTAMPTZ,UUID) TO authenticated;

-- Exact notification targets and badge queues must not filter an already
-- truncated result. Same source authorization and DTOs as the canonical queues.
CREATE OR REPLACE FUNCTION public.admin_support_case_queue_filtered(p_queue TEXT DEFAULT 'all',p_source UUID DEFAULT NULL,p_limit INTEGER DEFAULT 100)
RETURNS TABLE(support_case_id UUID,source_kind TEXT,source_id UUID,member_id UUID,category TEXT,priority TEXT,status TEXT,assignee_id UUID,assignee_name TEXT,sla_due_at TIMESTAMPTZ,first_response_at TIMESTAMPTZ,resolved_at TIMESTAMPTZ,created_at TIMESTAMPTZ,updated_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF NOT public.claim_rate_limit('staff_source_queue',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_queue IS NULL OR p_queue NOT IN ('all','open') OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_queue' USING ERRCODE='22023'; END IF;
  RETURN QUERY SELECT c.support_case_id,c.source_kind,c.source_id,c.member_id,c.category,c.priority,c.status,c.assigned_to,u.display_name,c.sla_due_at,c.first_response_at,c.resolved_at,c.created_at,c.updated_at
    FROM private.support_cases c LEFT JOIN public.users u ON u.user_id=c.assigned_to
    WHERE (p_source IS NULL OR c.support_case_id=p_source) AND (p_queue='all' OR c.status NOT IN ('resolved','closed'))
    ORDER BY (c.status NOT IN ('resolved','closed')) DESC,c.sla_due_at,c.created_at DESC,c.support_case_id LIMIT p_limit;
END;
$$;
CREATE OR REPLACE FUNCTION public.admin_legal_request_queue_filtered(p_queue TEXT DEFAULT 'all',p_source UUID DEFAULT NULL,p_limit INTEGER DEFAULT 100)
RETURNS TABLE(legal_request_id UUID,request_type TEXT,jurisdiction TEXT,scope_code TEXT,status TEXT,requester_verified BOOLEAN,due_at TIMESTAMPTZ,created_by UUID,approved_by UUID,approved_at TIMESTAMPTZ,approval_reason_code TEXT,manifest_recorded BOOLEAN,fulfilled_at TIMESTAMPTZ,completion_recorded BOOLEAN,created_at TIMESTAMPTZ,updated_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF NOT public.claim_rate_limit('staff_source_queue',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_queue IS NULL OR p_queue NOT IN ('all','awaiting_approval') OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_queue' USING ERRCODE='22023'; END IF;
  RETURN QUERY SELECT r.legal_request_id,r.request_type,r.jurisdiction,r.scope_code,r.status,r.requester_verified,r.due_at,r.created_by,r.approved_by,r.approved_at,r.approval_reason_code,r.disclosure_manifest_hash IS NOT NULL,r.fulfilled_at,r.completion_receipt_hash IS NOT NULL,r.created_at,r.updated_at
    FROM private.legal_requests r
    WHERE (p_source IS NULL OR r.legal_request_id=p_source) AND (p_queue='all' OR r.status='awaiting_approval')
    ORDER BY (r.status NOT IN ('rejected','fulfilled','closed')) DESC,r.due_at,r.created_at DESC,r.legal_request_id LIMIT p_limit;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_support_case_queue_filtered(TEXT,UUID,INTEGER),public.admin_legal_request_queue_filtered(TEXT,UUID,INTEGER) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_support_case_queue_filtered(TEXT,UUID,INTEGER),public.admin_legal_request_queue_filtered(TEXT,UUID,INTEGER) TO authenticated;
SELECT public.record_migration('20261029090002','staff_inbox_filters');
NOTIFY pgrst,'reload schema';
