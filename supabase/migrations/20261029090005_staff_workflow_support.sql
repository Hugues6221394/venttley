-- CLI-created 20260925061628; ordered after future-dated dependencies.
-- Additive support workflow reads + checked update; legacy contracts remain.
CREATE OR REPLACE FUNCTION public.admin_support_assignees(p_query TEXT DEFAULT '')
RETURNS TABLE(staff_id UUID,display_name TEXT,username TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF p_query IS NULL OR length(p_query)>50 THEN RAISE EXCEPTION 'invalid_query' USING ERRCODE='22023'; END IF;
  IF NOT public.claim_rate_limit('support_assignees_read',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  RETURN QUERY SELECT u.user_id,u.display_name::TEXT,u.anonymous_pseudonym::TEXT
  FROM public.users u
  WHERE u.user_role::TEXT IN ('super_admin','admin','support')
    AND public.is_staff(u.user_id,ARRAY['super_admin','admin','support'])
    AND (p_query='' OR starts_with(lower(u.display_name),lower(trim(p_query)))
      OR starts_with(lower(u.anonymous_pseudonym),lower(trim(p_query))))
  ORDER BY lower(u.display_name),u.user_id LIMIT 25;
END;
$$;

CREATE INDEX IF NOT EXISTS support_cases_workflow_order_idx
  ON private.support_cases(sla_due_at,support_case_id);

CREATE OR REPLACE FUNCTION public.admin_support_work_queue(
  p_queue TEXT DEFAULT 'open',p_owner TEXT DEFAULT 'all',p_priority TEXT DEFAULT 'all',
  p_after_due TIMESTAMPTZ DEFAULT NULL,p_after_id UUID DEFAULT NULL,p_limit INTEGER DEFAULT 31
) RETURNS TABLE (
  support_case_id UUID,source_kind TEXT,source_id UUID,member_id UUID,category TEXT,priority TEXT,status TEXT,
  assignee_id UUID,assignee_name TEXT,sla_due_at TIMESTAMPTZ,first_response_at TIMESTAMPTZ,resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ,updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF p_queue IS NULL OR p_queue NOT IN ('open','all','resolved','closed')
    OR p_owner IS NULL OR p_owner NOT IN ('all','mine','unassigned')
    OR p_priority IS NULL OR p_priority NOT IN ('all','low','normal','high','critical')
    OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 51
    OR (p_after_due IS NULL)<>(p_after_id IS NULL)
    OR (p_after_due IS NOT NULL AND NOT isfinite(p_after_due)) THEN
    RAISE EXCEPTION 'invalid_queue' USING ERRCODE='22023';
  END IF;
  IF NOT public.claim_rate_limit('support_work_queue_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  RETURN QUERY SELECT c.support_case_id,c.source_kind,c.source_id,c.member_id,c.category,c.priority,c.status,c.assigned_to,
    u.display_name,c.sla_due_at,c.first_response_at,c.resolved_at,c.created_at,c.updated_at
  FROM private.support_cases c LEFT JOIN public.users u ON u.user_id=c.assigned_to
  WHERE (p_queue='all' OR (p_queue='open' AND c.status NOT IN ('resolved','closed')) OR c.status=p_queue)
    AND (p_owner='all' OR (p_owner='mine' AND c.assigned_to=auth.uid()) OR (p_owner='unassigned' AND c.assigned_to IS NULL))
    AND (p_priority='all' OR c.priority=p_priority)
    AND (p_after_due IS NULL OR (c.sla_due_at,c.support_case_id)>(p_after_due,p_after_id))
  ORDER BY c.sla_due_at,c.support_case_id LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_support_case_checked(
  p_operation UUID,p_case UUID,p_status TEXT,p_priority TEXT,p_assignee UUID,p_expected_updated_at TIMESTAMPTZ
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE stamp TIMESTAMPTZ; request JSONB:=jsonb_build_object('case',p_case,'status',p_status,'priority',p_priority,'assignee',p_assignee);
BEGIN
  IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  -- An exact retry returns its existing receipt, including after a later edit.
  IF private.admin_operation_existing(auth.uid(),p_operation,'support.update',request) IS NOT NULL THEN RETURN; END IF;
  SELECT updated_at INTO stamp FROM private.support_cases WHERE support_case_id=p_case FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'support_case_not_found' USING ERRCODE='P0002'; END IF;
  -- This is a business conflict, not a serialization failure. SQLSTATE 40001
  -- invites PostgREST transaction retries and can turn a stale form into a
  -- gateway timeout. Return a deterministic HTTP 409 instead.
  IF p_expected_updated_at IS NULL OR stamp IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'workflow_conflict' USING ERRCODE='PT409'; END IF;
  PERFORM public.admin_update_support_case(p_operation,p_case,p_status,p_priority,p_assignee);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_support_assignees(TEXT),public.admin_support_work_queue(TEXT,TEXT,TEXT,TIMESTAMPTZ,UUID,INTEGER),public.admin_update_support_case_checked(UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_support_assignees(TEXT),public.admin_support_work_queue(TEXT,TEXT,TEXT,TIMESTAMPTZ,UUID,INTEGER),public.admin_update_support_case_checked(UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ) TO authenticated;
SELECT public.record_migration('20261029090005','staff_workflow_support');
NOTIFY pgrst,'reload schema';
