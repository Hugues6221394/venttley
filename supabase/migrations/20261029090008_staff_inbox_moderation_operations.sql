-- CLI-generated 20260926220308, ordered after existing future-dated inbox dependencies.
-- Additive. No source, retention or audience switch is enabled by this migration.
ALTER TABLE private.staff_inbox_control
 ADD COLUMN moderation_events_enabled BOOLEAN NOT NULL DEFAULT false,
 ADD COLUMN delivery_retention_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE private.staff_event_outbox DROP CONSTRAINT staff_event_outbox_kind_check;
ALTER TABLE private.staff_event_outbox ADD CONSTRAINT staff_event_outbox_kind_check CHECK(kind IN
 ('support_assigned','support_sla_breached','legal_review_requested','moderation_assigned','moderation_review_requested'));

CREATE TABLE private.staff_inbox_runtime (
 singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK(singleton),
 batch_at TIMESTAMPTZ,
 delivered_events INTEGER NOT NULL DEFAULT 0 CHECK(delivered_events>=0),
 failed_attempts INTEGER NOT NULL DEFAULT 0 CHECK(failed_attempts>=0),
 max_delivery_lag_seconds NUMERIC,
 retention_at TIMESTAMPTZ,
 pruned_deliveries INTEGER NOT NULL DEFAULT 0 CHECK(pruned_deliveries>=0)
);
INSERT INTO private.staff_inbox_runtime DEFAULT VALUES;
ALTER TABLE private.staff_inbox_runtime ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.staff_inbox_runtime FROM PUBLIC,anon,authenticated;
CREATE INDEX staff_delivery_retention_idx ON private.staff_inbox_deliveries(delivered_at,event_id,recipient_id);
CREATE INDEX staff_outbox_oldest_pending_idx ON private.staff_event_outbox(created_at) WHERE status='pending';
CREATE INDEX moderation_second_review_notice_idx ON public.moderation_case_events(case_id,created_at DESC,event_id DESC)
 WHERE kind='status_changed' AND detail->>'to'='awaiting_second_review';

CREATE OR REPLACE FUNCTION private.can_read_staff_event(p_actor UUID,p_kind TEXT,p_source UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT CASE
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
    SELECT e.actor_id FROM public.moderation_case_events e WHERE e.case_id=c.case_id
     AND e.kind='status_changed' AND e.detail->>'to'='awaiting_second_review'
    ORDER BY e.created_at DESC,e.event_id DESC LIMIT 1) END)
 ELSE false END;
$$;
REVOKE ALL ON FUNCTION private.can_read_staff_event(UUID,TEXT,UUID) FROM PUBLIC,anon,authenticated;

-- Serialize the canonical before/after snapshot, including callers of the
-- legacy RPCs. Without this lock two equal concurrent requests can both record
-- a transition from the old state and produce duplicate notifications.
CREATE OR REPLACE FUNCTION public.admin_assign_case(p_case UUID,p_assignee UUID DEFAULT NULL,p_reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_before public.moderation_cases; v_actor UUID:=auth.uid();
BEGIN
 IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','moderator']) THEN RAISE EXCEPTION 'forbidden'; END IF;
 SELECT * INTO v_before FROM public.moderation_cases WHERE case_id=p_case FOR UPDATE;
 IF v_before.case_id IS NULL THEN RAISE EXCEPTION 'case not found'; END IF;
 IF p_assignee IS NOT NULL AND NOT public.is_staff(p_assignee,ARRAY['super_admin','admin','moderator']) THEN RAISE EXCEPTION 'assignee is not a moderator'; END IF;
 UPDATE public.moderation_cases SET assignee_id=p_assignee,assigned_at=CASE WHEN p_assignee IS NULL THEN NULL ELSE now() END,
  status=CASE WHEN p_assignee IS NULL THEN status WHEN status IN ('open','reopened') THEN 'in_review' ELSE status END,
  first_action_at=COALESCE(first_action_at,now()),updated_at=now() WHERE case_id=p_case;
 INSERT INTO public.moderation_case_events(case_id,kind,actor_id,actor_role,detail,note)
 SELECT p_case,CASE WHEN p_assignee IS NULL THEN 'unassigned' ELSE 'assigned' END,v_actor,u.user_role::TEXT,
  jsonb_build_object('from',v_before.assignee_id,'to',p_assignee),p_reason FROM public.users u WHERE u.user_id=v_actor;
 PERFORM public.admin_log('case.assign','moderation_case',p_case,v_before.target_type,
  jsonb_build_object('assignee_id',v_before.assignee_id),jsonb_build_object('assignee_id',p_assignee),p_reason,'{}'::JSONB);
END $$;
REVOKE ALL ON FUNCTION public.admin_assign_case(UUID,UUID,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_assign_case(UUID,UUID,TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_case_status(p_case UUID,p_status TEXT,p_note TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_before public.moderation_cases; v_actor UUID:=auth.uid();
BEGIN
 IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','moderator']) THEN RAISE EXCEPTION 'forbidden'; END IF;
 IF p_status NOT IN ('open','in_review','awaiting_second_review','escalated','reopened') THEN RAISE EXCEPTION 'status % must be set through admin_decide_case',p_status; END IF;
 SELECT * INTO v_before FROM public.moderation_cases WHERE case_id=p_case FOR UPDATE;
 IF v_before.case_id IS NULL THEN RAISE EXCEPTION 'case not found'; END IF;
 UPDATE public.moderation_cases SET status=p_status,first_action_at=COALESCE(first_action_at,now()),updated_at=now() WHERE case_id=p_case;
 INSERT INTO public.moderation_case_events(case_id,kind,actor_id,actor_role,detail,note)
 SELECT p_case,CASE WHEN p_status='escalated' THEN 'escalated' WHEN p_status='reopened' THEN 'reopened' ELSE 'status_changed' END,
  v_actor,u.user_role::TEXT,jsonb_build_object('from',v_before.status,'to',p_status),p_note FROM public.users u WHERE u.user_id=v_actor;
 PERFORM public.admin_log('case.status','moderation_case',p_case,v_before.target_type,
  jsonb_build_object('status',v_before.status),jsonb_build_object('status',p_status),p_note,'{}'::JSONB);
END $$;
REVOKE ALL ON FUNCTION public.admin_set_case_status(UUID,TEXT,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_set_case_status(UUID,TEXT,TEXT) TO authenticated;

-- Canonical append-only events provide stable deduplication keys. Do not copy
-- evidence, notes, target/member IDs or arbitrary destinations into the outbox.
CREATE FUNCTION private.enqueue_moderation_staff_event()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c public.moderation_cases;
BEGIN
 IF NOT (SELECT enabled AND moderation_events_enabled FROM private.staff_inbox_control WHERE singleton) THEN RETURN NEW; END IF;
 SELECT * INTO c FROM public.moderation_cases WHERE case_id=NEW.case_id;
 IF NOT FOUND OR c.status='resolved' THEN RETURN NEW; END IF;
 IF NEW.kind='assigned' AND c.assignee_id IS NOT NULL AND NEW.detail->>'from' IS DISTINCT FROM NEW.detail->>'to' THEN
  INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
  VALUES('moderation-event:'||NEW.event_id,'moderation_assigned',c.case_id,c.assignee_id,
   CASE WHEN c.severity='critical' THEN 'critical' ELSE 'info' END) ON CONFLICT(event_key) DO NOTHING;
 ELSIF NEW.kind='status_changed' AND NEW.detail->>'to'='awaiting_second_review'
  AND NEW.detail->>'from' IS DISTINCT FROM NEW.detail->>'to' AND c.status='awaiting_second_review' AND NEW.actor_id IS NOT NULL THEN
  INSERT INTO private.staff_event_outbox(event_key,kind,source_id,severity)
  VALUES('moderation-event:'||NEW.event_id,'moderation_review_requested',c.case_id,
   CASE WHEN c.severity='critical' THEN 'critical' ELSE 'warning' END) ON CONFLICT(event_key) DO NOTHING;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.enqueue_moderation_staff_event() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER moderation_staff_inbox_event AFTER INSERT ON public.moderation_case_events
 FOR EACH ROW EXECUTE FUNCTION private.enqueue_moderation_staff_event();

CREATE FUNCTION public.admin_configure_staff_inbox_operations(p_operation UUID,p_moderation BOOLEAN,p_retention BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); request JSONB:=jsonb_build_object('moderation',p_moderation,'retention',p_retention);
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 IF p_moderation IS NULL OR p_retention IS NULL THEN RAISE EXCEPTION 'invalid_rollout'; END IF;
 IF private.admin_operation_existing(actor,p_operation,'staff_inbox.operations',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('staff_inbox_operations',60,10) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 UPDATE private.staff_inbox_control SET moderation_events_enabled=p_moderation,delivery_retention_enabled=p_retention WHERE singleton;
 PERFORM private.record_operational_audit(actor,'staff_inbox.operations','staff_inbox',p_operation,'Staff notification operations','release_control',request);
 PERFORM private.record_admin_operation(actor,p_operation,'staff_inbox.operations',request,p_operation);
END $$;
REVOKE ALL ON FUNCTION public.admin_configure_staff_inbox_operations(UUID,BOOLEAN,BOOLEAN) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_configure_staff_inbox_operations(UUID,BOOLEAN,BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION private.process_staff_inbox(p_limit INTEGER DEFAULT 100)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e private.staff_event_outbox%ROWTYPE; processed INTEGER:=0; delivered INTEGER:=0; failed INTEGER:=0; lag NUMERIC; max_lag NUMERIC;
BEGIN
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_limit'; END IF;
 IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-inbox-worker',0)) THEN RETURN 0; END IF;
 -- Coordinate with rollout/recovery: disabling waits for this bounded batch.
 PERFORM 1 FROM private.staff_inbox_control WHERE singleton AND enabled FOR SHARE;
 IF NOT FOUND THEN RETURN 0; END IF;
 INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
 SELECT 'support-sla:'||c.support_case_id||':'||c.sla_due_at::TEXT,'support_sla_breached',c.support_case_id,c.assigned_to,'critical'
 FROM private.support_cases c WHERE c.status NOT IN ('resolved','closed') AND c.sla_due_at<now()
 AND NOT EXISTS(SELECT 1 FROM private.staff_event_outbox o WHERE o.event_key='support-sla:'||c.support_case_id||':'||c.sla_due_at::TEXT)
 ORDER BY c.sla_due_at,c.support_case_id LIMIT p_limit ON CONFLICT(event_key) DO NOTHING;
 FOR e IN SELECT * FROM private.staff_event_outbox WHERE status='pending' AND next_attempt_at<=now()
 ORDER BY next_attempt_at,event_id FOR UPDATE SKIP LOCKED LIMIT p_limit LOOP
  BEGIN
   INSERT INTO private.staff_inbox_deliveries(event_id,recipient_id)
   SELECT e.event_id,u.user_id FROM public.users u
   -- Match idx_users_role's partial predicate without casting the indexed enum.
   WHERE u.user_role<>'normal' AND u.user_role IN ('super_admin','admin','moderator','support')
    AND u.user_role::TEXT=ANY((SELECT audience_roles FROM private.staff_inbox_control WHERE singleton)::TEXT[])
    AND (e.intended_recipient IS NULL OR u.user_id=e.intended_recipient)
    AND private.can_read_staff_event(u.user_id,e.kind,e.source_id)
    AND (e.kind NOT IN ('support_assigned','moderation_assigned') OR e.severity='critical' OR COALESCE(
     (SELECT p.assignment_notifications FROM private.staff_inbox_preferences p WHERE p.staff_id=u.user_id),true))
   ON CONFLICT(recipient_id,event_id) DO NOTHING;
   IF EXISTS(SELECT 1 FROM private.staff_inbox_deliveries d WHERE d.event_id=e.event_id) THEN
    UPDATE private.staff_event_outbox SET status='delivered',delivered_at=clock_timestamp(),attempts=attempts+1,last_error_code=NULL WHERE event_id=e.event_id;
    delivered:=delivered+1;lag:=greatest(0,extract(epoch FROM clock_timestamp()-e.created_at));
    max_lag:=CASE WHEN max_lag IS NULL THEN lag ELSE greatest(max_lag,lag) END;
   ELSE
    UPDATE private.staff_event_outbox SET status='skipped',delivered_at=clock_timestamp(),attempts=attempts+1,last_error_code=NULL WHERE event_id=e.event_id;
   END IF;
   processed:=processed+1;
  EXCEPTION WHEN OTHERS THEN
   failed:=failed+1;
   UPDATE private.staff_event_outbox SET attempts=attempts+1,status=CASE WHEN attempts+1>=5 THEN 'failed' ELSE 'pending' END,
    next_attempt_at=now()+make_interval(secs=>LEAST(3600,30*(2^attempts)::INTEGER)),last_error_code=SQLSTATE WHERE event_id=e.event_id;
  END;
 END LOOP;
 PERFORM private.refresh_staff_attention();
 UPDATE private.staff_inbox_control SET worker_at=clock_timestamp() WHERE singleton;
 UPDATE private.staff_inbox_runtime SET batch_at=clock_timestamp(),delivered_events=delivered,failed_attempts=failed,max_delivery_lag_seconds=max_lag WHERE singleton;
 RETURN processed;
END $$;
REVOKE ALL ON FUNCTION private.process_staff_inbox(INTEGER) FROM PUBLIC,anon,authenticated;

-- Retain durable keys so SLA reconciliation cannot recreate historical events.
-- Keep failed/pending events, all legal and moderation notices, all
-- source records and audit/operation receipts. Purge only old delivery records.
CREATE FUNCTION private.prune_staff_inbox_deliveries(p_limit INTEGER DEFAULT 500)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE removed INTEGER;
BEGIN
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'invalid_limit'; END IF;
 IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-inbox-worker',0)) THEN RETURN 0; END IF;
 PERFORM 1 FROM private.staff_inbox_control WHERE singleton AND enabled AND delivery_retention_enabled FOR SHARE;
 IF NOT FOUND THEN RETURN 0; END IF;
 WITH expired AS (
  SELECT d.event_id,d.recipient_id FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
  WHERE d.delivered_at<now()-interval '90 days' AND o.status IN ('delivered','skipped')
   -- Moderation/legal notices remain until their evidence-retention policy is
   -- approved. Excluding the entire source avoids racing a newly placed hold.
   AND o.kind IN ('support_assigned','support_sla_breached')
  ORDER BY d.delivered_at,d.event_id,d.recipient_id LIMIT p_limit FOR UPDATE OF d SKIP LOCKED
 ), removed_rows AS (
  DELETE FROM private.staff_inbox_deliveries d USING expired e WHERE d.event_id=e.event_id AND d.recipient_id=e.recipient_id RETURNING 1
 ) SELECT count(*)::INTEGER INTO removed FROM removed_rows;
 UPDATE private.staff_inbox_runtime SET retention_at=clock_timestamp(),pruned_deliveries=removed WHERE singleton;
 RETURN removed;
END $$;
REVOKE ALL ON FUNCTION private.prune_staff_inbox_deliveries(INTEGER) FROM PUBLIC,anon,authenticated;
SELECT cron.schedule('staff-inbox-delivery-retention','17 * * * *','SELECT private.prune_staff_inbox_deliveries(500)');

CREATE OR REPLACE FUNCTION public.admin_staff_inbox_health()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF NOT public.claim_rate_limit('staff_inbox_health',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 RETURN (SELECT jsonb_build_object('enabled',c.enabled,'audience_roles',c.audience_roles,'worker_at',c.worker_at,
  'worker_stale',c.worker_at IS NULL OR c.worker_at<now()-interval '2 minutes',
  'moderation_events_enabled',c.moderation_events_enabled,'delivery_retention_enabled',c.delivery_retention_enabled,
  'pending',(SELECT count(*) FROM private.staff_event_outbox WHERE status='pending'),
  'failed',(SELECT count(*) FROM private.staff_event_outbox WHERE status='failed'),
  'oldest_pending_at',(SELECT min(created_at) FROM private.staff_event_outbox WHERE status='pending'),
  'runtime',(SELECT to_jsonb(r)-'singleton' FROM private.staff_inbox_runtime r WHERE singleton))
 FROM private.staff_inbox_control c WHERE singleton);
END $$;
REVOKE ALL ON FUNCTION public.admin_staff_inbox_health() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_staff_inbox_health() TO authenticated;

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
  OR p_category IS NULL OR p_category NOT IN ('all','support','legal','moderation')
  OR p_severity IS NULL OR p_severity NOT IN ('all','info','warning','critical')
  OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR ((p_before_at IS NULL)<>(p_before_id IS NULL))
  OR (p_before_at IS NOT NULL AND NOT isfinite(p_before_at)) THEN RAISE EXCEPTION 'invalid_inbox_query' USING ERRCODE='22023'; END IF;
 IF NOT (SELECT enabled AND public.is_staff(actor,audience_roles) FROM private.staff_inbox_control WHERE singleton) THEN RETURN; END IF;
 RETURN QUERY SELECT o.event_id,o.kind,o.severity,o.source_id,
  CASE WHEN o.kind='legal_review_requested' THEN '/legal-requests'
   WHEN o.kind IN ('moderation_assigned','moderation_review_requested') THEN '/moderation/cases/'||o.source_id ELSE '/support/cases' END,
  d.delivered_at,d.read_at
 FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
 WHERE d.recipient_id=actor AND private.can_read_staff_event(actor,o.kind,o.source_id)
  AND (p_filter<>'unread' OR d.read_at IS NULL)
  AND (p_filter<>'urgent' OR o.severity='critical')
  AND (p_filter<>'assigned' OR
   (o.kind IN ('support_assigned','support_sla_breached') AND EXISTS(SELECT 1 FROM private.support_cases c WHERE c.support_case_id=o.source_id AND c.assigned_to=actor AND c.status NOT IN ('resolved','closed')))
   OR (o.kind IN ('moderation_assigned','moderation_review_requested') AND EXISTS(SELECT 1 FROM public.moderation_cases c WHERE c.case_id=o.source_id AND c.assignee_id=actor AND c.status<>'resolved')))
  AND (p_category='all' OR (p_category='legal' AND o.kind='legal_review_requested')
   OR (p_category='support' AND o.kind IN ('support_assigned','support_sla_breached'))
   OR (p_category='moderation' AND o.kind IN ('moderation_assigned','moderation_review_requested')))
  AND (p_severity='all' OR o.severity=p_severity)
  AND (p_before_at IS NULL OR (d.delivered_at,d.event_id)<(p_before_at,p_before_id))
 ORDER BY d.delivered_at DESC,d.event_id DESC LIMIT p_limit;
END $$;
REVOKE ALL ON FUNCTION public.admin_staff_inbox_page(TEXT,TEXT,TEXT,INTEGER,TIMESTAMPTZ,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_staff_inbox_page(TEXT,TEXT,TEXT,INTEGER,TIMESTAMPTZ,UUID) TO authenticated;

-- Keep the earlier API correct for clients that have not adopted categories.
CREATE OR REPLACE FUNCTION public.admin_staff_inbox(p_filter TEXT DEFAULT 'all',p_limit INTEGER DEFAULT 30,p_before_at TIMESTAMPTZ DEFAULT NULL,p_before_id UUID DEFAULT NULL)
RETURNS TABLE(event_id UUID,kind TEXT,severity TEXT,source_id UUID,destination TEXT,delivered_at TIMESTAMPTZ,read_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM public.admin_staff_inbox_page(p_filter,'all','all',p_limit,p_before_at,p_before_id);
END $$;
REVOKE ALL ON FUNCTION public.admin_staff_inbox(TEXT,INTEGER,TIMESTAMPTZ,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_staff_inbox(TEXT,INTEGER,TIMESTAMPTZ,UUID) TO authenticated;
SELECT public.record_migration('20261029090008','staff_inbox_moderation_operations');
NOTIFY pgrst,'reload schema';
