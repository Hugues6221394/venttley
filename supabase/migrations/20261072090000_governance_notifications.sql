-- Governance events in the staff inbox. Ships disabled (governance_events_enabled).
-- Requires access_review_ledger, staff_promotion_approvals, broadcast_approvals,
-- and the staff inbox migrations through 20261029090011_incident_notifications.
BEGIN;
ALTER TABLE private.staff_inbox_control ADD COLUMN governance_events_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE private.staff_event_outbox DROP CONSTRAINT staff_event_outbox_kind_check;
ALTER TABLE private.staff_event_outbox ADD CONSTRAINT staff_event_outbox_kind_check CHECK(kind IN (
 'support_assigned','support_sla_breached','legal_review_requested','moderation_assigned','moderation_review_requested',
 'job_push_attention','job_email_attention','job_media_attention','impact_report_ready','incident_changed','incident_overdue',
 'access_review_assigned','access_review_overdue','promotion_review_requested','promotion_ready','broadcast_review_requested','broadcast_ready'));

CREATE FUNCTION public.admin_configure_governance_notices(p_operation UUID,p_enabled BOOLEAN) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); request JSONB:=jsonb_build_object('enabled',p_enabled);
BEGIN
 PERFORM private.require_promotion_actor(true); -- Active super admin, AAL2 and live Auth session.
 IF p_operation IS NULL OR p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
 -- Serialize controls, receipts and producer batches; do not restore stale retry intent.
 PERFORM 1 FROM private.staff_inbox_control WHERE singleton FOR UPDATE;
 IF private.admin_operation_existing(actor,p_operation,'governance.notices',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('governance_notices_configure',60,10) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 UPDATE private.staff_inbox_control SET governance_events_enabled=p_enabled WHERE singleton;
 PERFORM private.record_operational_audit(actor,'governance.notices','staff_inbox_control',p_operation,'Governance notices','release_control',request);
 PERFORM private.record_admin_operation(actor,p_operation,'governance.notices',request,p_operation);
END $$;
REVOKE ALL ON FUNCTION public.admin_configure_governance_notices(UUID,BOOLEAN) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.admin_configure_governance_notices(UUID,BOOLEAN) TO authenticated;

CREATE FUNCTION private.can_read_governance_notice(p_actor UUID,p_kind TEXT,p_source UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT COALESCE((SELECT enabled AND governance_events_enabled FROM private.staff_inbox_control WHERE singleton),false)
 AND CASE
 WHEN p_kind IN ('access_review_assigned','access_review_overdue') THEN
  public.is_staff(p_actor,ARRAY['super_admin'])
  AND (SELECT enabled FROM private.access_review_control WHERE singleton)
  AND EXISTS(SELECT 1 FROM private.access_review_campaigns c JOIN private.access_review_items i USING(campaign_id)
   LEFT JOIN public.users s ON s.user_id=i.subject_id
   WHERE c.campaign_id=p_source AND c.closed_at IS NULL AND i.reviewer_id=p_actor AND i.subject_id<>p_actor
   AND (p_kind<>'access_review_overdue' OR c.due_at<now())
   AND (i.decision IN ('pending','revoke_required') OR
    (i.decision='retained' AND (i.valid_until<=now() OR s.user_id IS NULL OR s.user_role::TEXT IS DISTINCT FROM i.role_snapshot
      OR s.account_status::TEXT IS DISTINCT FROM i.status_snapshot OR s.deactivated_at IS DISTINCT FROM i.deactivated_snapshot)) OR
    (i.decision='revoked' AND s.user_role IN ('super_admin','admin','moderator','support','analyst','read_only_auditor'))))
 WHEN p_kind IN ('promotion_review_requested','promotion_ready') THEN
  public.is_staff(p_actor,ARRAY['super_admin'])
  AND (SELECT enabled FROM private.promotion_control WHERE singleton)
  AND EXISTS(SELECT 1 FROM private.staff_promotion_approvals a JOIN public.users t ON t.user_id=a.target_id
   WHERE a.approval_id=p_source AND a.expires_at>now()
   AND public.is_staff(a.requested_by,ARRAY['super_admin'])
   AND a.requester_revision=COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=a.requested_by),0)
   AND t.user_role::TEXT=a.target_role AND t.account_status='active' AND t.deactivated_at IS NULL
   AND a.target_revision=COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=a.target_id),0)
   AND CASE WHEN p_kind='promotion_review_requested' THEN a.state='pending' AND p_actor NOT IN (a.requested_by,a.target_id)
    ELSE a.state='approved' AND p_actor=a.requested_by AND public.is_staff(a.approved_by,ARRAY['super_admin'])
     AND a.approver_revision=COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=a.approved_by),0) END)
 WHEN p_kind IN ('broadcast_review_requested','broadcast_ready') THEN
  public.is_staff(p_actor,CASE WHEN p_kind='broadcast_review_requested' THEN ARRAY['super_admin'] ELSE ARRAY['super_admin','admin'] END)
  AND (SELECT enabled FROM private.broadcast_approval_control WHERE singleton)
  AND EXISTS(SELECT 1 FROM private.broadcast_approvals a WHERE a.approval_id=p_source
   AND a.expires_at>now() AND a.publication_expires_at>now()
   AND public.is_staff(a.requested_by,ARRAY['super_admin','admin'])
   AND a.requester_revision=COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=a.requested_by),0)
   AND CASE WHEN p_kind='broadcast_review_requested' THEN a.state='pending' AND p_actor<>a.requested_by
    ELSE a.state='approved' AND p_actor=a.requested_by AND public.is_staff(a.approved_by,ARRAY['super_admin'])
     AND a.approver_revision=COALESCE((SELECT version FROM private.staff_authority_revisions WHERE user_id=a.approved_by),0) END)
 ELSE false END;
$$;
REVOKE ALL ON FUNCTION private.can_read_governance_notice(UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated,service_role;

-- Metadata only. Stable review keys group a campaign per reviewer; approval
-- state/version keys distinguish review from explicit execution work.
CREATE INDEX access_review_open_deadlines ON private.access_review_campaigns(due_at,campaign_id) WHERE closed_at IS NULL;
CREATE INDEX access_review_reviewer ON private.access_review_items(campaign_id,reviewer_id);
CREATE INDEX promotion_pending_notices ON private.staff_promotion_approvals(created_at,approval_id) WHERE state IN ('pending','approved');
CREATE INDEX broadcast_pending_notices ON private.broadcast_approvals(created_at,approval_id) WHERE state IN ('pending','approved');
CREATE VIEW private.governance_notice_candidates AS
 SELECT DISTINCT 'governance:'||k.kind||':'||c.campaign_id||':'||i.reviewer_id AS event_key,k.kind,
 c.campaign_id AS source_id,i.reviewer_id AS intended_recipient,
 CASE WHEN k.kind='access_review_overdue' THEN 'critical' ELSE 'warning' END AS severity,c.created_at AS ready_at
 FROM private.access_review_campaigns c JOIN (SELECT DISTINCT campaign_id,reviewer_id FROM private.access_review_items) i USING(campaign_id)
 CROSS JOIN (VALUES('access_review_assigned'),('access_review_overdue'))k(kind)
 WHERE c.closed_at IS NULL AND private.can_read_governance_notice(i.reviewer_id,k.kind,c.campaign_id)
 UNION ALL
 SELECT 'governance:promotion:'||a.approval_id||':'||a.version,
 CASE WHEN a.state='pending' THEN 'promotion_review_requested' ELSE 'promotion_ready' END,
 a.approval_id,CASE WHEN a.state='approved' THEN a.requested_by ELSE NULL::UUID END,'warning',a.created_at
 FROM private.staff_promotion_approvals a
 WHERE a.state IN ('pending','approved') AND a.expires_at>now()
 AND (SELECT enabled FROM private.promotion_control WHERE singleton)
 UNION ALL
 SELECT 'governance:broadcast:'||a.approval_id||':'||a.version,
 CASE WHEN a.state='pending' THEN 'broadcast_review_requested' ELSE 'broadcast_ready' END,
 a.approval_id,CASE WHEN a.state='approved' THEN a.requested_by ELSE NULL::UUID END,'warning',a.created_at
 FROM private.broadcast_approvals a
 WHERE a.state IN ('pending','approved') AND a.expires_at>now() AND a.publication_expires_at>now()
 AND (SELECT enabled FROM private.broadcast_approval_control WHERE singleton);
REVOKE ALL ON private.governance_notice_candidates FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.enqueue_governance_notices(p_source UUID DEFAULT NULL,p_limit INTEGER DEFAULT 100)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE amount INTEGER;
BEGIN
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_limit'; END IF;
 -- Do not lock sources here: workflow transactions already hold source locks.
 -- The shared rollout lock ensures disable waits for an in-flight enqueue.
 PERFORM 1 FROM private.staff_inbox_control WHERE singleton AND enabled AND governance_events_enabled FOR SHARE;
 IF NOT FOUND THEN RETURN 0; END IF;
 INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
 SELECT c.event_key,c.kind,c.source_id,c.intended_recipient,c.severity
 FROM private.governance_notice_candidates c
 WHERE (p_source IS NULL OR c.source_id=p_source)
 AND NOT EXISTS(SELECT 1 FROM private.staff_event_outbox o WHERE o.event_key=c.event_key)
 ORDER BY c.ready_at,c.event_key LIMIT p_limit ON CONFLICT(event_key) DO NOTHING;
 GET DIAGNOSTICS amount=ROW_COUNT; RETURN amount;
END $$;
REVOKE ALL ON FUNCTION private.enqueue_governance_notices(UUID,INTEGER) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION private.enqueue_governance_event() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF TG_TABLE_NAME='access_review_events' THEN
  PERFORM private.enqueue_governance_notices(NEW.campaign_id);
 ELSE
  PERFORM private.enqueue_governance_notices(NEW.approval_id);
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.enqueue_governance_event() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER access_review_notices AFTER INSERT ON private.access_review_events FOR EACH ROW EXECUTE FUNCTION private.enqueue_governance_event();
CREATE TRIGGER promotion_notices AFTER INSERT ON private.staff_promotion_events FOR EACH ROW EXECUTE FUNCTION private.enqueue_governance_event();
CREATE TRIGGER broadcast_approval_notices AFTER INSERT ON private.broadcast_approval_events FOR EACH ROW EXECUTE FUNCTION private.enqueue_governance_event();

CREATE FUNCTION private.governance_notice_deliverable(p_kind TEXT,p_source UUID,p_recipient UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.users u WHERE u.user_role<>'normal'
  AND u.user_role IN ('super_admin','admin')
  AND u.user_role::TEXT=ANY((SELECT audience_roles FROM private.staff_inbox_control WHERE singleton)::TEXT[])
  AND (p_recipient IS NULL OR u.user_id=p_recipient)
  AND private.can_read_governance_notice(u.user_id,p_kind,p_source));
$$;
REVOKE ALL ON FUNCTION private.governance_notice_deliverable(TEXT,UUID,UUID) FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX staff_governance_skipped ON private.staff_event_outbox(created_at,event_id)
 WHERE status='skipped' AND kind IN ('access_review_assigned','access_review_overdue','promotion_review_requested','promotion_ready','broadcast_review_requested','broadcast_ready');
CREATE FUNCTION private.reconcile_governance_notices() RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE recovered INTEGER;
BEGIN
 IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-inbox-worker',0)) THEN RETURN 0; END IF;
 PERFORM 1 FROM private.staff_inbox_control WHERE singleton AND enabled AND governance_events_enabled FOR SHARE;
 IF NOT FOUND THEN RETURN 0; END IF;
 -- A disabled source/audience may have caused the shared worker to skip work.
 -- Reconsider only currently deliverable skipped events; never auto-retry failed
 -- events or reset a delivered/read item. Existing delivery keys remain intact.
 WITH recoverable AS (
  SELECT o.event_id FROM private.staff_event_outbox o WHERE o.status='skipped'
   AND o.kind IN ('access_review_assigned','access_review_overdue','promotion_review_requested','promotion_ready','broadcast_review_requested','broadcast_ready')
   AND private.governance_notice_deliverable(o.kind,o.source_id,o.intended_recipient)
  ORDER BY o.created_at,o.event_id LIMIT 100 FOR UPDATE SKIP LOCKED
 ) UPDATE private.staff_event_outbox o SET status='pending',attempts=0,next_attempt_at=now(),last_error_code=NULL,delivered_at=NULL
 FROM recoverable r WHERE o.event_id=r.event_id;
 GET DIAGNOSTICS recovered=ROW_COUNT;
 RETURN recovered+private.enqueue_governance_notices(NULL,100);
END $$;
REVOKE ALL ON FUNCTION private.reconcile_governance_notices() FROM PUBLIC,anon,authenticated,service_role;
-- Registered only when this draft is promoted. Default-off control makes it inert.
SELECT cron.schedule('staff-governance-notices','* * * * *','SELECT private.reconcile_governance_notices()');

CREATE OR REPLACE FUNCTION private.can_read_staff_event(p_actor UUID,p_kind TEXT,p_source UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT CASE
 WHEN p_kind IN ('access_review_assigned','access_review_overdue','promotion_review_requested','promotion_ready','broadcast_review_requested','broadcast_ready') THEN private.can_read_governance_notice(p_actor,p_kind,p_source)
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
  OR p_category IS NULL OR p_category NOT IN ('all','support','legal','moderation','jobs','reports','incidents','governance')
  OR p_severity IS NULL OR p_severity NOT IN ('all','info','warning','critical')
  OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR ((p_before_at IS NULL)<>(p_before_id IS NULL))
  OR (p_before_at IS NOT NULL AND NOT isfinite(p_before_at)) THEN RAISE EXCEPTION 'invalid_inbox_query' USING ERRCODE='22023'; END IF;
 IF NOT (SELECT enabled AND public.is_staff(actor,audience_roles) FROM private.staff_inbox_control WHERE singleton) THEN RETURN; END IF;
 RETURN QUERY SELECT o.event_id,o.kind,o.severity,o.source_id,
  CASE WHEN o.kind IN ('access_review_assigned','access_review_overdue') THEN '/staff/access-reviews?campaign='||o.source_id
   WHEN o.kind IN ('promotion_review_requested','promotion_ready') THEN '/approvals?source='||o.source_id
   WHEN o.kind IN ('broadcast_review_requested','broadcast_ready') THEN '/broadcasts?source='||o.source_id
   WHEN o.kind IN ('incident_changed','incident_overdue') THEN '/incidents/records/'||o.source_id
   WHEN o.kind='legal_review_requested' THEN '/legal-requests'
   WHEN o.kind IN ('moderation_assigned','moderation_review_requested') THEN '/moderation/cases/'||o.source_id
   WHEN o.kind='impact_report_ready' THEN '/impact/reports/'||o.source_id
   WHEN o.kind LIKE 'job_%' THEN '/jobs#'||CASE o.kind WHEN 'job_push_attention' THEN 'push-failures' WHEN 'job_email_attention' THEN 'email-failures' ELSE 'media-stalled' END
   ELSE '/support/cases' END,d.delivered_at,d.read_at
 FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
 WHERE d.recipient_id=actor AND private.can_read_staff_event(actor,o.kind,o.source_id)
  AND (p_filter<>'unread' OR d.read_at IS NULL) AND (p_filter<>'urgent' OR o.severity='critical')
  AND (p_filter<>'assigned' OR (o.kind IN ('access_review_assigned','access_review_overdue','promotion_ready','broadcast_ready') AND private.can_read_governance_notice(actor,o.kind,o.source_id)) OR (o.kind IN ('incident_changed','incident_overdue') AND private.can_read_incident_notice(actor,o.kind,o.source_id)) OR
   (o.kind IN ('support_assigned','support_sla_breached') AND EXISTS(SELECT 1 FROM private.support_cases c WHERE c.support_case_id=o.source_id AND c.assigned_to=actor AND c.status NOT IN ('resolved','closed')))
   OR (o.kind IN ('moderation_assigned','moderation_review_requested') AND EXISTS(SELECT 1 FROM public.moderation_cases c WHERE c.case_id=o.source_id AND c.assignee_id=actor AND c.status<>'resolved')))
  AND (p_category='all' OR (p_category='governance' AND o.kind IN ('access_review_assigned','access_review_overdue','promotion_review_requested','promotion_ready','broadcast_review_requested','broadcast_ready')) OR (p_category='incidents' AND o.kind IN ('incident_changed','incident_overdue')) OR (p_category='legal' AND o.kind='legal_review_requested')
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

-- Recovery operators may inspect/retry metadata for currently deliverable
-- governance events without becoming recipients or gaining decision authority.
CREATE OR REPLACE FUNCTION public.admin_staff_inbox_failures(p_after_time TIMESTAMPTZ DEFAULT NULL,p_after_id UUID DEFAULT NULL,p_limit INT DEFAULT 31)
RETURNS TABLE(event_id UUID,kind TEXT,severity TEXT,attempts INT,last_error_code TEXT,created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 51 OR (p_after_time IS NULL)<>(p_after_id IS NULL)
 OR (p_after_time IS NOT NULL AND NOT isfinite(p_after_time)) THEN RAISE EXCEPTION 'invalid_cursor' USING ERRCODE='22023'; END IF;
 IF NOT public.claim_rate_limit('staff_inbox_failures',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 RETURN QUERY SELECT o.event_id,o.kind,o.severity,o.attempts,o.last_error_code,o.created_at
 FROM private.staff_event_outbox o WHERE o.status='failed'
 AND (private.can_read_staff_event(auth.uid(),o.kind,o.source_id) OR private.governance_notice_deliverable(o.kind,o.source_id,o.intended_recipient))
 AND (p_after_time IS NULL OR (o.created_at,o.event_id)>(p_after_time,p_after_id))
 ORDER BY o.created_at,o.event_id LIMIT p_limit;
END $$;

CREATE OR REPLACE FUNCTION public.admin_retry_staff_notification(p_operation UUID,p_event UUID,p_reason_code TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e private.staff_event_outbox; request JSONB:=jsonb_build_object('event',p_event,'reason',p_reason_code);
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 -- Match the worker's lock order before taking control/event row locks. The
 -- worker updates the control timestamp after locking events; reversing that
 -- order here could deadlock recovery against a delivery in progress.
 IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-inbox-worker',0)) THEN
   RAISE EXCEPTION 'workflow_conflict' USING ERRCODE='PT409';
 END IF;
 -- Hold the control row through commit. Rollback disabling the worker cannot
 -- race a recovery command into re-enabling processing or changing its audience.
 PERFORM 1 FROM private.staff_inbox_control WHERE singleton AND enabled FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'staff_inbox_disabled' USING ERRCODE='55000'; END IF;
 IF p_reason_code IS NULL OR p_reason_code NOT IN ('transient_resolved','configuration_fixed','reviewed_retry') THEN RAISE EXCEPTION 'invalid_reason' USING ERRCODE='22023'; END IF;
 SELECT * INTO e FROM private.staff_event_outbox WHERE event_id=p_event FOR UPDATE;
 IF NOT FOUND OR NOT (private.can_read_staff_event(auth.uid(),e.kind,e.source_id) OR private.governance_notice_deliverable(e.kind,e.source_id,e.intended_recipient)) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF private.admin_operation_existing(auth.uid(),p_operation,'staff_inbox.retry',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('staff_inbox_retry',60,10) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF e.status<>'failed' THEN RAISE EXCEPTION 'workflow_conflict' USING ERRCODE='PT409'; END IF;
 -- Keep event identity, recipients/read states, and prior failure class in the
 -- immutable audit. The same worker performs delivery with its unique keys.
 UPDATE private.staff_event_outbox SET status='pending',attempts=0,next_attempt_at=now(),last_error_code=NULL,delivered_at=NULL WHERE event_id=p_event;
 PERFORM private.record_operational_audit(auth.uid(),'staff_inbox.retry','staff_event',p_event,'Staff notification',p_reason_code,
   jsonb_build_object('prior_attempts',e.attempts,'prior_error_code',e.last_error_code));
 PERFORM private.record_admin_operation(auth.uid(),p_operation,'staff_inbox.retry',request,p_event);
END $$;
REVOKE ALL ON FUNCTION public.admin_staff_inbox_failures(TIMESTAMPTZ,UUID,INT),public.admin_retry_staff_notification(UUID,UUID,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_staff_inbox_failures(TIMESTAMPTZ,UUID,INT),public.admin_retry_staff_notification(UUID,UUID,TEXT) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
