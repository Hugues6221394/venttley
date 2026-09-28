-- CLI-generated 20260924223209, ordered after the existing future-dated
-- foundation. Extends the existing worker and RPC; no new scheduler or rollout.
ALTER TABLE private.staff_attention_snapshots
  DROP CONSTRAINT IF EXISTS staff_attention_snapshots_queue_key_check;
ALTER TABLE private.staff_attention_snapshots
  ADD CONSTRAINT staff_attention_snapshots_queue_key_check
    CHECK(queue_key IN ('support','legal','moderation','appeals')),
  ADD COLUMN IF NOT EXISTS invalidated BOOLEAN NOT NULL DEFAULT true;

-- Unknown until reconciled, never a fabricated zero. These rows are private.
INSERT INTO private.staff_attention_snapshots(queue_key,open_count,invalidated)
SELECT k,0,true FROM unnest(ARRAY['moderation','appeals','support','legal']) k
ON CONFLICT(queue_key) DO NOTHING;

-- One transactional marker per source transaction/queue, not a shared hot
-- counter. Readers only perform indexed EXISTS probes; no content retained.
CREATE TABLE IF NOT EXISTS private.staff_attention_changes (
  queue_key TEXT NOT NULL REFERENCES private.staff_attention_snapshots(queue_key),
  transaction_id BIGINT NOT NULL,
  PRIMARY KEY(queue_key,transaction_id)
);
ALTER TABLE private.staff_attention_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.staff_attention_changes FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.invalidate_staff_attention()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT (SELECT enabled FROM private.staff_inbox_control WHERE singleton) THEN RETURN NULL; END IF;
  INSERT INTO private.staff_attention_changes(queue_key,transaction_id)
    VALUES(TG_ARGV[0],txid_current()) ON CONFLICT DO NOTHING;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION private.invalidate_staff_attention() FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE TRIGGER reports_attention_dirty AFTER INSERT OR UPDATE OR DELETE ON public.reports
  FOR EACH STATEMENT EXECUTE FUNCTION private.invalidate_staff_attention('moderation');
CREATE OR REPLACE TRIGGER appeals_attention_dirty AFTER INSERT OR UPDATE OR DELETE ON public.moderation_appeals
  FOR EACH STATEMENT EXECUTE FUNCTION private.invalidate_staff_attention('appeals');
CREATE OR REPLACE TRIGGER support_attention_dirty AFTER INSERT OR UPDATE OR DELETE ON private.support_cases
  FOR EACH STATEMENT EXECUTE FUNCTION private.invalidate_staff_attention('support');
CREATE OR REPLACE TRIGGER legal_attention_dirty AFTER INSERT OR UPDATE OR DELETE ON private.legal_requests
  FOR EACH STATEMENT EXECUTE FUNCTION private.invalidate_staff_attention('legal');

-- Disabled pilots produce no change-log writes. Re-enabling must invalidate
-- all old snapshots before exposing a possibly unobserved source change.
CREATE OR REPLACE FUNCTION private.invalidate_attention_rollout()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NEW.enabled IS DISTINCT FROM OLD.enabled THEN
    UPDATE private.staff_attention_snapshots SET invalidated=true;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.invalidate_attention_rollout() FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE TRIGGER attention_rollout_dirty AFTER UPDATE OF enabled ON private.staff_inbox_control
  FOR EACH ROW EXECUTE FUNCTION private.invalidate_attention_rollout();

CREATE OR REPLACE FUNCTION private.refresh_staff_attention()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE key TEXT; seen BIGINT[]; n BIGINT;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-attention-refresh',0)) THEN RETURN; END IF;
  FOREACH key IN ARRAY ARRAY['appeals','legal','moderation','support'] LOOP
    -- Capture visible, committed markers BEFORE counting. Any later/uncommitted
    -- source change retains its marker, even if its transaction ID is lower.
    -- Bound cleanup; remaining backlog conservatively keeps the count stale.
    SELECT array_agg(transaction_id) INTO seen FROM (
      SELECT transaction_id FROM private.staff_attention_changes WHERE queue_key=key
      ORDER BY transaction_id LIMIT 1000) pending;
    SELECT CASE key
      WHEN 'moderation' THEN (SELECT count(*) FROM public.reports WHERE is_resolved=false)
      WHEN 'appeals' THEN (SELECT count(*) FROM public.moderation_appeals WHERE status='open')
      WHEN 'support' THEN (SELECT count(*) FROM private.support_cases WHERE status NOT IN ('resolved','closed'))
      WHEN 'legal' THEN (SELECT count(*) FROM private.legal_requests WHERE status='awaiting_approval')
    END INTO n;
    UPDATE private.staff_attention_snapshots SET open_count=n,
      measured_at=clock_timestamp(),invalidated=false WHERE queue_key=key;
    DELETE FROM private.staff_attention_changes WHERE queue_key=key AND transaction_id=ANY(seen);
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION private.refresh_staff_attention() FROM PUBLIC,anon,authenticated;

-- Same bounded, retry-safe event delivery; only the aggregate refresh changes.
CREATE OR REPLACE FUNCTION private.process_staff_inbox(p_limit INTEGER DEFAULT 100)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e private.staff_event_outbox%ROWTYPE; processed INTEGER:=0;
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_limit'; END IF;
  IF NOT (SELECT enabled FROM private.staff_inbox_control WHERE singleton) THEN RETURN 0; END IF;
  IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-inbox-worker',0)) THEN RETURN 0; END IF;
  INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
  SELECT 'support-sla:'||c.support_case_id||':'||c.sla_due_at::TEXT,'support_sla_breached',
    c.support_case_id,c.assigned_to,'critical'
  FROM private.support_cases c
  WHERE c.status NOT IN ('resolved','closed') AND c.sla_due_at<now()
    AND NOT EXISTS(SELECT 1 FROM private.staff_event_outbox o WHERE o.event_key='support-sla:'||c.support_case_id||':'||c.sla_due_at::TEXT)
  ORDER BY c.sla_due_at,c.support_case_id LIMIT p_limit ON CONFLICT(event_key) DO NOTHING;
  FOR e IN SELECT * FROM private.staff_event_outbox
    WHERE status='pending' AND next_attempt_at<=now()
    ORDER BY next_attempt_at,event_id FOR UPDATE SKIP LOCKED LIMIT p_limit
  LOOP
    BEGIN
      INSERT INTO private.staff_inbox_deliveries(event_id,recipient_id)
      SELECT e.event_id,u.user_id FROM public.users u
      WHERE u.user_role::TEXT IN ('super_admin','admin','support')
        AND u.user_role::TEXT=ANY((SELECT audience_roles FROM private.staff_inbox_control WHERE singleton)::TEXT[])
        AND (e.intended_recipient IS NULL OR u.user_id=e.intended_recipient)
        AND private.can_read_staff_event(u.user_id,e.kind,e.source_id)
        AND (e.kind<>'support_assigned' OR e.severity='critical' OR COALESCE(
          (SELECT p.assignment_notifications FROM private.staff_inbox_preferences p WHERE p.staff_id=u.user_id),true))
      ON CONFLICT(recipient_id,event_id) DO NOTHING;
      UPDATE private.staff_event_outbox SET status=CASE WHEN EXISTS(
        SELECT 1 FROM private.staff_inbox_deliveries d WHERE d.event_id=e.event_id
      ) THEN 'delivered' ELSE 'skipped' END,delivered_at=now(),attempts=attempts+1,last_error_code=NULL WHERE event_id=e.event_id;
      processed:=processed+1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE private.staff_event_outbox SET attempts=attempts+1,
        status=CASE WHEN attempts+1>=5 THEN 'failed' ELSE 'pending' END,
        next_attempt_at=now()+make_interval(secs=>LEAST(3600,30*(2^attempts)::INTEGER)),
        last_error_code=SQLSTATE WHERE event_id=e.event_id;
    END;
  END LOOP;
  PERFORM private.refresh_staff_attention();
  UPDATE private.staff_inbox_control SET worker_at=clock_timestamp() WHERE singleton;
  RETURN processed;
END;
$$;
REVOKE ALL ON FUNCTION private.process_staff_inbox(INTEGER) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.admin_staff_attention()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); control private.staff_inbox_control%ROWTYPE; unread INTEGER; queues JSONB;
BEGIN
  IF NOT public.is_staff(actor,ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF NOT public.claim_rate_limit('staff_attention_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO control FROM private.staff_inbox_control WHERE singleton;
  IF NOT control.enabled OR NOT public.is_staff(actor,control.audience_roles) THEN RETURN jsonb_build_object('enabled',false); END IF;
  SELECT count(*) INTO unread FROM (SELECT 1 FROM private.staff_inbox_deliveries d
    JOIN private.staff_event_outbox o USING(event_id)
    WHERE d.recipient_id=actor AND d.read_at IS NULL
      AND private.can_read_staff_event(actor,o.kind,o.source_id) LIMIT 100) capped;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('key',s.queue_key,'count',s.open_count,
    'measured_at',s.measured_at,'stale',s.invalidated OR EXISTS(
      SELECT 1 FROM private.staff_attention_changes c WHERE c.queue_key=s.queue_key)
      OR s.measured_at<now()-interval '2 minutes'
      OR s.measured_at>now()+interval '1 minute') ORDER BY s.queue_key),'[]'::JSONB)
  INTO queues FROM private.staff_attention_snapshots s WHERE
    (s.queue_key='support' AND public.is_staff(actor,ARRAY['super_admin','admin','support'])) OR
    (s.queue_key='legal' AND public.is_staff(actor,ARRAY['super_admin'])) OR
    (s.queue_key IN ('moderation','appeals') AND public.is_staff(actor,ARRAY['super_admin','admin','moderator']));
  RETURN jsonb_build_object('enabled',true,'unread_count',LEAST(unread,99),'unread_more',unread>99,
    'generated_at',now(),'worker_at',control.worker_at,'queues',queues);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_staff_attention() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_staff_attention() TO authenticated;
SELECT public.record_migration('20261029090004','staff_attention_consistency');
NOTIFY pgrst,'reload schema';
