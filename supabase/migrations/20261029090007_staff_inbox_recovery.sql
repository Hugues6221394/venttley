-- CLI-created 20260926090432; ordered after future-dated inbox dependencies.
-- Batch 4 first slice: recovery contracts, no producer/pilot activation.
CREATE INDEX IF NOT EXISTS staff_outbox_failed_cursor_idx ON private.staff_event_outbox(created_at,event_id) WHERE status='failed';
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
 AND private.can_read_staff_event(auth.uid(),o.kind,o.source_id)
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
 IF NOT FOUND OR NOT private.can_read_staff_event(auth.uid(),e.kind,e.source_id) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
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
SELECT public.record_migration('20261029090007','staff_inbox_recovery');
NOTIFY pgrst,'reload schema';
