-- CLI-created 20260927213805; additive extension of the existing staff outbox.
ALTER TABLE private.incident_control ADD COLUMN notifications_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE private.staff_event_outbox DROP CONSTRAINT staff_event_outbox_kind_check;
ALTER TABLE private.staff_event_outbox ADD CONSTRAINT staff_event_outbox_kind_check CHECK(kind IN
 ('support_assigned','support_sla_breached','legal_review_requested','moderation_assigned','moderation_review_requested',
  'job_push_attention','job_email_attention','job_media_attention','impact_report_ready','incident_changed','incident_overdue'));
CREATE FUNCTION public.admin_configure_incident_notices(p_operation UUID,p_enabled BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); request JSONB:=jsonb_build_object('enabled',p_enabled);
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 IF p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_rollout' USING ERRCODE='22023'; END IF;
 IF private.admin_operation_existing(actor,p_operation,'incident.notices',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('incident_configure',60,10) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 UPDATE private.incident_control SET notifications_enabled=p_enabled WHERE singleton;
 PERFORM private.record_operational_audit(actor,'incident.notices','incident_control',p_operation,'Incident notices','release_control',request);
 PERFORM private.record_admin_operation(actor,p_operation,'incident.notices',request,p_operation);
END $$;
REVOKE ALL ON FUNCTION public.admin_configure_incident_notices(UUID,BOOLEAN) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_configure_incident_notices(UUID,BOOLEAN) TO authenticated;
CREATE FUNCTION private.can_read_incident_notice(p_actor UUID,p_kind TEXT,p_source UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT public.is_staff(p_actor,ARRAY['super_admin','admin'])
 AND (SELECT enabled AND notifications_enabled FROM private.incident_control WHERE singleton)
 AND EXISTS(SELECT 1 FROM private.operational_incidents i WHERE i.incident_id=p_source AND (i.commander=p_actor OR p_actor=ANY(i.responders))
 AND (p_kind='incident_changed' OR p_kind='incident_overdue' AND i.status NOT IN ('resolved','reviewed') AND i.response_due_at<now()));
$$;
REVOKE ALL ON FUNCTION private.can_read_incident_notice(UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.enqueue_incident_notice() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT (SELECT enabled AND notifications_enabled FROM private.incident_control WHERE singleton) OR NOT (SELECT enabled FROM private.staff_inbox_control WHERE singleton) THEN RETURN NEW; END IF;
 INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
 SELECT 'incident-event:'||NEW.event_id||':'||recipient,'incident_changed',i.incident_id,recipient,
 CASE WHEN i.severity='sev1' THEN 'critical' ELSE 'warning' END
 FROM private.operational_incidents i CROSS JOIN LATERAL (SELECT DISTINCT unnest(array_prepend(i.commander,i.responders)) AS recipient)t
 WHERE i.incident_id=NEW.incident_id AND public.is_staff(recipient,ARRAY['super_admin','admin'])
 ON CONFLICT(event_key) DO NOTHING;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.enqueue_incident_notice() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER incident_notices AFTER INSERT ON private.incident_events FOR EACH ROW EXECUTE FUNCTION private.enqueue_incident_notice();
CREATE FUNCTION private.reconcile_incident_deadlines() RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE n INTEGER;
BEGIN
 IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-inbox-worker',0)) THEN RETURN 0; END IF;
 PERFORM 1 FROM private.staff_inbox_control WHERE singleton AND enabled FOR SHARE; IF NOT FOUND THEN RETURN 0; END IF;
 PERFORM 1 FROM private.incident_control WHERE singleton AND enabled AND notifications_enabled FOR SHARE; IF NOT FOUND THEN RETURN 0; END IF;
 INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
 SELECT 'incident-deadline:'||i.incident_id||':'||extract(epoch FROM i.response_due_at)::TEXT||':'||recipient,'incident_overdue',i.incident_id,recipient,'critical'
 FROM (SELECT i.* FROM private.operational_incidents i WHERE i.status NOT IN ('resolved','reviewed') AND i.response_due_at<now()
  AND EXISTS(SELECT 1 FROM unnest(array_prepend(i.commander,i.responders))r WHERE public.is_staff(r,ARRAY['super_admin','admin']) AND NOT EXISTS(
   SELECT 1 FROM private.staff_event_outbox o WHERE o.event_key='incident-deadline:'||i.incident_id||':'||extract(epoch FROM i.response_due_at)::TEXT||':'||r))
  ORDER BY i.response_due_at,i.incident_id LIMIT 100)i
 CROSS JOIN LATERAL (SELECT DISTINCT unnest(array_prepend(i.commander,i.responders)) AS recipient)t
 WHERE public.is_staff(recipient,ARRAY['super_admin','admin']) ON CONFLICT(event_key) DO NOTHING;
 GET DIAGNOSTICS n=ROW_COUNT; RETURN n;
END $$;
REVOKE ALL ON FUNCTION private.reconcile_incident_deadlines() FROM PUBLIC,anon,authenticated;
SELECT cron.schedule('staff-incident-deadlines','* * * * *','SELECT private.reconcile_incident_deadlines()');
CREATE OR REPLACE FUNCTION private.can_read_staff_event(p_actor UUID,p_kind TEXT,p_source UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT CASE
 WHEN p_kind IN ('incident_changed','incident_overdue') THEN private.can_read_incident_notice(p_actor,p_kind,p_source)
 WHEN p_kind IN ('support_assigned','support_sla_breached') THEN
  public.is_staff(p_actor,ARRAY['super_admin','admin','support']) AND EXISTS(SELECT 1 FROM private.support_cases WHERE support_case_id=p_source)
 WHEN p_kind='legal_review_requested' THEN
  public.is_staff(p_actor,ARRAY['super_admin']) AND EXISTS(SELECT 1 FROM private.legal_requests WHERE legal_request_id=p_source AND created_by<>p_actor)
 WHEN p_kind IN ('moderation_assigned','moderation_review_requested') THEN
  (SELECT moderation_events_enabled FROM private.staff_inbox_control WHERE singleton)
  AND public.is_staff(p_actor,ARRAY['super_admin','admin','moderator'])
  AND EXISTS(SELECT 1 FROM public.moderation_cases c WHERE c.case_id=p_source AND
   CASE WHEN p_kind='moderation_assigned' THEN c.assignee_id=p_actor AND c.status<>'resolved'
   ELSE c.status='awaiting_second_review' AND p_actor<>(
    SELECT e.actor_id FROM public.moderation_case_events e WHERE e.case_id=c.case_id AND e.kind='status_changed' AND e.detail->>'to'='awaiting_second_review'
    ORDER BY e.created_at DESC,e.event_id DESC LIMIT 1) END)
 WHEN p_kind IN ('job_push_attention','job_email_attention','job_media_attention') THEN
  (SELECT job_events_enabled FROM private.staff_inbox_control WHERE singleton)
  AND public.is_staff(p_actor,ARRAY['super_admin','admin'])
  AND EXISTS(SELECT 1 FROM private.staff_job_attention s WHERE s.source_id=p_source
   AND p_kind='job_'||s.queue||'_attention' AND s.observed_count>0 AND s.measured_at>now()-interval '2 minutes')
 WHEN p_kind='impact_report_ready' THEN
  (SELECT report_events_enabled FROM private.staff_inbox_control WHERE singleton)
  AND public.is_staff(p_actor,ARRAY['super_admin','admin','analyst','read_only_auditor'])
  AND EXISTS(SELECT 1 FROM private.impact_report_snapshots r WHERE r.report_id=p_source AND r.generated_by=p_actor
   AND r.status IN ('generated','published') AND r.checksum IS NOT NULL)
 ELSE false END;
$$;
REVOKE ALL ON FUNCTION private.can_read_staff_event(UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated;


CREATE OR REPLACE FUNCTION public.admin_staff_inbox_page(
 p_filter TEXT DEFAULT 'all',p_category TEXT DEFAULT 'all',p_severity TEXT DEFAULT 'all',
 p_limit INTEGER DEFAULT 30,p_before_at TIMESTAMPTZ DEFAULT NULL,p_before_id UUID DEFAULT NULL
) RETURNS TABLE(event_id UUID,kind TEXT,severity TEXT,source_id UUID,destination TEXT,delivered_at TIMESTAMPTZ,read_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid();
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF NOT public.claim_rate_limit('staff_inbox_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF p_filter IS NULL OR p_filter NOT IN ('all','unread','urgent','assigned')
  OR p_category IS NULL OR p_category NOT IN ('all','support','legal','moderation','jobs','reports','incidents')
  OR p_severity IS NULL OR p_severity NOT IN ('all','info','warning','critical')
  OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR ((p_before_at IS NULL)<>(p_before_id IS NULL))
  OR (p_before_at IS NOT NULL AND NOT isfinite(p_before_at)) THEN RAISE EXCEPTION 'invalid_inbox_query' USING ERRCODE='22023'; END IF;
 IF NOT (SELECT enabled AND public.is_staff(actor,audience_roles) FROM private.staff_inbox_control WHERE singleton) THEN RETURN; END IF;
 RETURN QUERY SELECT o.event_id,o.kind,o.severity,o.source_id,
  CASE WHEN o.kind IN ('incident_changed','incident_overdue') THEN '/incidents/records/'||o.source_id
   WHEN o.kind='legal_review_requested' THEN '/legal-requests'
   WHEN o.kind IN ('moderation_assigned','moderation_review_requested') THEN '/moderation/cases/'||o.source_id
   WHEN o.kind='impact_report_ready' THEN '/impact/reports/'||o.source_id
   WHEN o.kind LIKE 'job_%' THEN '/jobs#'||CASE o.kind WHEN 'job_push_attention' THEN 'push-failures' WHEN 'job_email_attention' THEN 'email-failures' ELSE 'media-stalled' END
   ELSE '/support/cases' END,d.delivered_at,d.read_at
 FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
 WHERE d.recipient_id=actor AND private.can_read_staff_event(actor,o.kind,o.source_id)
  AND (p_filter<>'unread' OR d.read_at IS NULL) AND (p_filter<>'urgent' OR o.severity='critical')
  AND (p_filter<>'assigned' OR (o.kind IN ('incident_changed','incident_overdue') AND private.can_read_incident_notice(actor,o.kind,o.source_id)) OR
   (o.kind IN ('support_assigned','support_sla_breached') AND EXISTS(SELECT 1 FROM private.support_cases c WHERE c.support_case_id=o.source_id AND c.assigned_to=actor AND c.status NOT IN ('resolved','closed')))
   OR (o.kind IN ('moderation_assigned','moderation_review_requested') AND EXISTS(SELECT 1 FROM public.moderation_cases c WHERE c.case_id=o.source_id AND c.assignee_id=actor AND c.status<>'resolved')))
  AND (p_category='all' OR (p_category='incidents' AND o.kind IN ('incident_changed','incident_overdue')) OR (p_category='legal' AND o.kind='legal_review_requested')
   OR (p_category='support' AND o.kind IN ('support_assigned','support_sla_breached'))
   OR (p_category='moderation' AND o.kind IN ('moderation_assigned','moderation_review_requested'))
   OR (p_category='jobs' AND o.kind IN ('job_push_attention','job_email_attention','job_media_attention'))
   OR (p_category='reports' AND o.kind='impact_report_ready'))
  AND (p_severity='all' OR o.severity=p_severity)
  AND (p_before_at IS NULL OR (d.delivered_at,d.event_id)<(p_before_at,p_before_id))
 ORDER BY d.delivered_at DESC,d.event_id DESC LIMIT p_limit;
END $$;
REVOKE ALL ON FUNCTION public.admin_staff_inbox_page(TEXT,TEXT,TEXT,INTEGER,TIMESTAMPTZ,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_staff_inbox_page(TEXT,TEXT,TEXT,INTEGER,TIMESTAMPTZ,UUID) TO authenticated;

SELECT public.record_migration('20261029090011','incident_notifications');
NOTIFY pgrst,'reload schema';
