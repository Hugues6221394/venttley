-- CLI-created 20260928104838; follows this branch's future-dated dependencies.
-- Additive, disabled by default. No incident history or permission broadening.
ALTER TABLE private.incident_control
 ADD COLUMN audience_roles TEXT[] NOT NULL DEFAULT ARRAY['super_admin'],
 ADD CONSTRAINT incident_audience_valid CHECK (
   cardinality(audience_roles) BETWEEN 1 AND 2
   AND audience_roles <@ ARRAY['super_admin','admin']::TEXT[]
   AND 'super_admin'=ANY(audience_roles) AND array_position(audience_roles,NULL) IS NULL);

CREATE FUNCTION private.incident_pilot_member(p_actor UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT COALESCE((SELECT enabled AND public.is_staff(p_actor,audience_roles)
 FROM private.incident_control WHERE singleton),false);
$$;
REVOKE ALL ON FUNCTION private.incident_pilot_member(UUID) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.admin_configure_incident_audience(p_operation UUID,p_roles TEXT[])
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); request JSONB;
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 IF p_roles IS NULL OR cardinality(p_roles) NOT BETWEEN 1 AND 2 OR array_ndims(p_roles)<>1
  OR NOT p_roles <@ ARRAY['super_admin','admin']::TEXT[] OR NOT 'super_admin'=ANY(p_roles)
  OR array_position(p_roles,NULL) IS NOT NULL
  OR cardinality(p_roles)<>(SELECT count(DISTINCT r) FROM unnest(p_roles)r)
 THEN RAISE EXCEPTION 'invalid_audience' USING ERRCODE='22023'; END IF;
 SELECT jsonb_build_object('roles',array_agg(r ORDER BY r)) INTO request FROM unnest(p_roles)r;
 IF private.admin_operation_existing(actor,p_operation,'incident.audience',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('incident_configure',60,10) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 UPDATE private.incident_control SET audience_roles=ARRAY(SELECT jsonb_array_elements_text(request->'roles')) WHERE singleton;
 PERFORM private.record_operational_audit(actor,'incident.audience','incident_control',p_operation,'Incident audience','release_control',request);
 PERFORM private.record_admin_operation(actor,p_operation,'incident.audience',request,p_operation);
END $$;
REVOKE ALL ON FUNCTION public.admin_configure_incident_audience(UUID,TEXT[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_configure_incident_audience(UUID,TEXT[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_incident_staff(p_query TEXT DEFAULT '')
RETURNS TABLE(staff_id UUID,display_name TEXT) LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF NOT private.incident_pilot_member(auth.uid()) THEN RETURN; END IF;
 IF p_query IS NULL OR length(p_query)>50 THEN RAISE EXCEPTION 'invalid_query' USING ERRCODE='22023'; END IF;
 IF NOT public.claim_rate_limit('incident_staff',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 RETURN QUERY SELECT u.user_id,u.display_name FROM public.users u WHERE u.user_role<>'normal' AND u.user_role IN ('super_admin','admin')
 AND private.incident_pilot_member(u.user_id) AND (p_query='' OR starts_with(lower(u.display_name),lower(btrim(p_query)))) ORDER BY u.display_name,u.user_id LIMIT 25;
END $$;

CREATE OR REPLACE FUNCTION public.admin_incident_mutate(p_operation UUID,p_incident UUID,p_version BIGINT,p_command TEXT,p_payload JSONB)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
<<mutation>>
DECLARE actor UUID:=auth.uid(); request JSONB; result UUID; i private.operational_incidents; allowed TEXT[]; note TEXT; command_owner UUID;
 services TEXT[]; responders UUID[]; due TIMESTAMPTZ; new_status TEXT; event_detail JSONB:='{}'; action_id UUID;
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 -- Configuration takes an exclusive lock; rollback waits for bounded writes.
 PERFORM 1 FROM private.incident_control WHERE singleton AND enabled AND public.is_staff(actor,audience_roles) FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'incident_disabled' USING ERRCODE='55000'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' OR octet_length(p_payload::TEXT)>12000 THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE='22023'; END IF;
 allowed:=CASE p_command WHEN 'declare' THEN ARRAY['title','severity','services','commander','responders','deadline','runbook','signal','note']
 WHEN 'coordinate' THEN ARRAY['severity','services','commander','responders','deadline','runbook','signal','note']
 WHEN 'transition' THEN ARRAY['status','note'] WHEN 'note' THEN ARRAY['note','kind']
 WHEN 'action_add' THEN ARRAY['title','owner','deadline','note'] WHEN 'action_complete' THEN ARRAY['action','note'] END;
 IF allowed IS NULL OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload)k WHERE NOT k=ANY(allowed)) THEN RAISE EXCEPTION 'invalid_command' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each(p_payload)e WHERE e.key NOT IN ('responders','services') AND jsonb_typeof(e.value) NOT IN ('string','null')) THEN RAISE EXCEPTION 'invalid_field_type' USING ERRCODE='22023'; END IF;
 note:=btrim(COALESCE(p_payload->>'note',''));
 IF length(note)>2000 OR note ~ '[<>]' OR note ~ '[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]' THEN RAISE EXCEPTION 'invalid_note' USING ERRCODE='22023'; END IF;
 request:=jsonb_build_object('incident',p_incident,'version',p_version,'command',p_command,'payload',p_payload);
 result:=private.admin_operation_existing(actor,p_operation,'incident.command',request);
 IF result IS NOT NULL THEN RETURN result; END IF;
 IF NOT public.claim_rate_limit('incident_command',60,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF p_command='declare' THEN
  IF p_incident IS NOT NULL OR p_version IS NOT NULL OR length(btrim(COALESCE(p_payload->>'title','')))=0 THEN RAISE EXCEPTION 'invalid_declaration' USING ERRCODE='22023'; END IF;
 ELSE
  SELECT * INTO i FROM private.operational_incidents WHERE incident_id=p_incident FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'incident_not_found' USING ERRCODE='P0002'; END IF;
  IF p_version IS NULL OR p_version<>i.version THEN RAISE EXCEPTION 'workflow_conflict' USING ERRCODE='PT409'; END IF;
  IF i.status='reviewed' THEN RAISE EXCEPTION 'incident_reviewed' USING ERRCODE='PT409'; END IF;
 END IF;
 IF p_command IN ('declare','coordinate') THEN
  IF jsonb_typeof(p_payload->'services') IS DISTINCT FROM 'array' OR jsonb_typeof(p_payload->'responders') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid_participants' USING ERRCODE='22023'; END IF;
  SELECT array_agg(DISTINCT value ORDER BY value) INTO services FROM jsonb_array_elements_text(p_payload->'services');
  SELECT COALESCE(array_agg(DISTINCT value::UUID ORDER BY value::UUID),'{}') INTO responders FROM jsonb_array_elements_text(p_payload->'responders');
  command_owner:=(p_payload->>'commander')::UUID; due:=(p_payload->>'deadline')::TIMESTAMPTZ;
  IF command_owner IS NULL OR NOT private.incident_pilot_member(command_owner) OR cardinality(responders)>20 OR
   EXISTS(SELECT 1 FROM unnest(responders)u WHERE u IS NULL OR NOT private.incident_pilot_member(u)) THEN RAISE EXCEPTION 'invalid_staff' USING ERRCODE='22023'; END IF;
  IF due IS NULL OR NOT isfinite(due) OR due>now()+interval '30 days' OR (p_command='declare' AND due<=now()) THEN RAISE EXCEPTION 'invalid_deadline' USING ERRCODE='22023'; END IF;
  IF p_command='declare' THEN
   INSERT INTO private.operational_incidents(title,severity,services,commander,responders,response_due_at,runbook,signal,created_by)
   VALUES(btrim(p_payload->>'title'),p_payload->>'severity',services,command_owner,responders,due,p_payload->>'runbook',NULLIF(p_payload->>'signal',''),actor) RETURNING * INTO i;
  ELSE
   UPDATE private.operational_incidents SET severity=p_payload->>'severity',services=mutation.services,commander=command_owner,
    responders=mutation.responders,response_due_at=due,runbook=p_payload->>'runbook',signal=NULLIF(p_payload->>'signal','') WHERE incident_id=i.incident_id;
  END IF;
  event_detail:=jsonb_build_object('severity',p_payload->>'severity','commander',command_owner,'responders',responders,'services',services,'deadline',due,'runbook',p_payload->>'runbook','signal',p_payload->>'signal');
 ELSIF p_command='transition' THEN
  new_status:=p_payload->>'status';
  IF note='' OR NOT COALESCE(CASE i.status WHEN 'declared' THEN new_status='investigating' WHEN 'investigating' THEN new_status='mitigating'
    WHEN 'mitigating' THEN new_status IN ('monitoring','investigating') WHEN 'monitoring' THEN new_status IN ('resolved','investigating')
    WHEN 'resolved' THEN new_status IN ('reviewed','investigating') ELSE false END,false) THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='22023'; END IF;
  IF new_status='reviewed' AND EXISTS(SELECT 1 FROM private.incident_actions WHERE incident_id=i.incident_id AND completed_at IS NULL) THEN RAISE EXCEPTION 'open_postmortem_actions' USING ERRCODE='PT409'; END IF;
  UPDATE private.operational_incidents SET status=new_status WHERE incident_id=i.incident_id;
  event_detail:=jsonb_build_object('from',i.status,'to',new_status);
 ELSIF p_command='note' THEN
  IF note='' OR p_payload->>'kind' IS NULL OR p_payload->>'kind' NOT IN ('update','decision','communication','postmortem') THEN RAISE EXCEPTION 'invalid_note_kind' USING ERRCODE='22023'; END IF;
  event_detail:=jsonb_build_object('kind',p_payload->>'kind');
 ELSIF p_command='action_add' THEN
  command_owner:=(p_payload->>'owner')::UUID;due:=(p_payload->>'deadline')::TIMESTAMPTZ;
  IF command_owner IS NULL OR NOT private.incident_pilot_member(command_owner) OR due IS NULL OR NOT isfinite(due) OR due<=now() OR due>now()+interval '365 days' THEN RAISE EXCEPTION 'invalid_action_owner_or_deadline' USING ERRCODE='22023'; END IF;
  IF (SELECT count(*) FROM private.incident_actions WHERE incident_id=i.incident_id)>=100 THEN RAISE EXCEPTION 'action_limit' USING ERRCODE='22023'; END IF;
  INSERT INTO private.incident_actions(incident_id,title,owner_id,due_at) VALUES(i.incident_id,btrim(p_payload->>'title'),command_owner,due) RETURNING incident_actions.action_id INTO action_id;
  event_detail:=jsonb_build_object('action',action_id,'owner',command_owner,'deadline',due);
 ELSE
  action_id:=(p_payload->>'action')::UUID;
  UPDATE private.incident_actions SET completed_at=now() WHERE incident_actions.action_id=mutation.action_id AND incident_id=i.incident_id AND completed_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'action_not_open' USING ERRCODE='PT409'; END IF;
  event_detail:=jsonb_build_object('action',action_id);
 END IF;
 IF p_command<>'declare' THEN UPDATE private.operational_incidents SET version=version+1,updated_at=clock_timestamp() WHERE incident_id=i.incident_id RETURNING * INTO i; END IF;
 INSERT INTO private.incident_events(incident_id,version,actor_id,kind,note,detail) VALUES(i.incident_id,i.version,actor,p_command,note,event_detail);
 PERFORM private.record_operational_audit(actor,'incident.'||p_command,'incident',i.incident_id,'Incident coordination','staff_response',jsonb_build_object('version',i.version,'status',i.status));
 PERFORM private.record_admin_operation(actor,p_operation,'incident.command',request,i.incident_id);
 RETURN i.incident_id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_incident_queue(p_filter TEXT DEFAULT 'active',p_severity TEXT DEFAULT 'all',p_before_at TIMESTAMPTZ DEFAULT NULL,p_before_id UUID DEFAULT NULL,p_limit INTEGER DEFAULT 31)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); rows JSONB; active_count INTEGER; overdue_count INTEGER; review_count INTEGER;
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF p_filter IS NULL OR p_filter NOT IN ('active','mine','all','review') OR p_severity IS NULL OR p_severity NOT IN ('all','sev1','sev2','sev3','sev4') OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 51 OR (p_before_at IS NULL)<>(p_before_id IS NULL) OR (p_before_at IS NOT NULL AND NOT isfinite(p_before_at)) THEN RAISE EXCEPTION 'invalid_queue' USING ERRCODE='22023'; END IF;
 IF NOT public.claim_rate_limit('incident_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF NOT private.incident_pilot_member(auth.uid()) THEN RETURN jsonb_build_object('enabled',false); END IF;
 SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC,r.incident_id DESC),'[]') INTO rows FROM (
  SELECT i.*,u.display_name AS commander_name FROM private.operational_incidents i LEFT JOIN public.users u ON u.user_id=i.commander
  WHERE (p_filter='all' OR p_filter='active' AND i.status NOT IN ('resolved','reviewed') OR p_filter='review' AND i.status='resolved' OR p_filter='mine' AND (i.commander=actor OR actor=ANY(i.responders)))
  AND (p_severity='all' OR i.severity=p_severity) AND (p_before_at IS NULL OR (i.created_at,i.incident_id)<(p_before_at,p_before_id))
  ORDER BY i.created_at DESC,i.incident_id DESC LIMIT p_limit)r;
 SELECT count(*) INTO active_count FROM (SELECT 1 FROM private.operational_incidents WHERE status NOT IN ('resolved','reviewed') LIMIT 1001)t;
 SELECT count(*) INTO overdue_count FROM (SELECT 1 FROM private.operational_incidents WHERE status NOT IN ('resolved','reviewed') AND response_due_at<now() LIMIT 1001)t;
 SELECT count(*) INTO review_count FROM (SELECT 1 FROM private.operational_incidents WHERE status='resolved' LIMIT 1001)t;
 RETURN jsonb_build_object('enabled',true,'measured_at',clock_timestamp(),'rows',rows,'active',active_count,'overdue',overdue_count,'review',review_count);
END $$;

CREATE OR REPLACE FUNCTION public.admin_incident_detail(p_incident UUID,p_before_version BIGINT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE incident JSONB; events JSONB; actions JSONB;
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF NOT public.claim_rate_limit('incident_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF NOT private.incident_pilot_member(auth.uid()) THEN RETURN jsonb_build_object('enabled',false); END IF;
 IF p_before_version IS NOT NULL AND p_before_version<1 THEN RAISE EXCEPTION 'invalid_cursor' USING ERRCODE='22023'; END IF;
 SELECT to_jsonb(i)||jsonb_build_object('commander_name',u.display_name,'responder_names',
  (SELECT COALESCE(jsonb_agg(jsonb_build_object('staff_id',r.id,'display_name',COALESCE(p.display_name,'Former staff member')) ORDER BY r.ordinal),'[]')
   FROM unnest(i.responders) WITH ORDINALITY r(id,ordinal) LEFT JOIN public.users p ON p.user_id=r.id))
 INTO incident FROM private.operational_incidents i LEFT JOIN public.users u ON u.user_id=i.commander WHERE incident_id=p_incident;
 IF incident IS NULL THEN RAISE EXCEPTION 'incident_not_found' USING ERRCODE='P0002'; END IF;
 SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.version DESC),'[]') INTO events FROM (SELECT e.*,u.display_name AS actor_name FROM private.incident_events e LEFT JOIN public.users u ON u.user_id=e.actor_id WHERE incident_id=p_incident AND (p_before_version IS NULL OR version<p_before_version) ORDER BY version DESC LIMIT 51)e;
 SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.created_at,a.action_id),'[]') INTO actions FROM (SELECT a.*,u.display_name AS owner_name FROM private.incident_actions a LEFT JOIN public.users u ON u.user_id=a.owner_id WHERE incident_id=p_incident ORDER BY created_at,action_id LIMIT 100)a;
 RETURN jsonb_build_object('enabled',true,'measured_at',clock_timestamp(),'incident',incident,'events',events,'actions',actions);
END $$;

CREATE OR REPLACE FUNCTION private.can_read_incident_notice(p_actor UUID,p_kind TEXT,p_source UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT private.incident_pilot_member(p_actor)
 AND (SELECT enabled AND notifications_enabled FROM private.incident_control WHERE singleton)
 AND EXISTS(SELECT 1 FROM private.operational_incidents i WHERE i.incident_id=p_source AND (i.commander=p_actor OR p_actor=ANY(i.responders))
 AND (p_kind='incident_changed' OR p_kind='incident_overdue' AND i.status NOT IN ('resolved','reviewed') AND i.response_due_at<now()));
$$;

CREATE OR REPLACE FUNCTION private.enqueue_incident_notice() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT (SELECT enabled AND notifications_enabled FROM private.incident_control WHERE singleton) OR NOT (SELECT enabled FROM private.staff_inbox_control WHERE singleton) THEN RETURN NEW; END IF;
 INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
 SELECT 'incident-event:'||NEW.event_id||':'||recipient,'incident_changed',i.incident_id,recipient,
 CASE WHEN i.severity='sev1' THEN 'critical' ELSE 'warning' END
 FROM private.operational_incidents i CROSS JOIN LATERAL (SELECT DISTINCT unnest(array_prepend(i.commander,i.responders)) AS recipient)t
 WHERE i.incident_id=NEW.incident_id AND private.incident_pilot_member(recipient)
 ON CONFLICT(event_key) DO NOTHING;
 RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION private.reconcile_incident_deadlines() RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE n INTEGER;
BEGIN
 IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-inbox-worker',0)) THEN RETURN 0; END IF;
 PERFORM 1 FROM private.staff_inbox_control WHERE singleton AND enabled FOR SHARE; IF NOT FOUND THEN RETURN 0; END IF;
 PERFORM 1 FROM private.incident_control WHERE singleton AND enabled AND notifications_enabled FOR SHARE; IF NOT FOUND THEN RETURN 0; END IF;
 INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
 SELECT 'incident-deadline:'||i.incident_id||':'||extract(epoch FROM i.response_due_at)::TEXT||':'||recipient,'incident_overdue',i.incident_id,recipient,'critical'
 FROM (SELECT i.* FROM private.operational_incidents i WHERE i.status NOT IN ('resolved','reviewed') AND i.response_due_at<now()
  AND EXISTS(SELECT 1 FROM unnest(array_prepend(i.commander,i.responders))r WHERE private.incident_pilot_member(r) AND NOT EXISTS(
   SELECT 1 FROM private.staff_event_outbox o WHERE o.event_key='incident-deadline:'||i.incident_id||':'||extract(epoch FROM i.response_due_at)::TEXT||':'||r))
  ORDER BY i.response_due_at,i.incident_id LIMIT 100)i
 CROSS JOIN LATERAL (SELECT DISTINCT unnest(array_prepend(i.commander,i.responders)) AS recipient)t
 WHERE private.incident_pilot_member(recipient) ON CONFLICT(event_key) DO NOTHING;
 GET DIAGNOSTICS n=ROW_COUNT; RETURN n;
END $$;

-- Reuse the canonical snapshot/transaction-marker worker. Counts are bounded
-- at 100 (displayed as 99+); polling never scans the incident source.
ALTER TABLE private.staff_attention_snapshots DROP CONSTRAINT staff_attention_snapshots_queue_key_check;
ALTER TABLE private.staff_attention_snapshots ADD CONSTRAINT staff_attention_snapshots_queue_key_check
 CHECK(queue_key IN ('support','legal','moderation','appeals','incidents'));
INSERT INTO private.staff_attention_snapshots(queue_key,open_count,invalidated)
 VALUES('incidents',0,true) ON CONFLICT(queue_key) DO NOTHING;
CREATE TRIGGER incidents_attention_dirty AFTER INSERT OR UPDATE OR DELETE ON private.operational_incidents
 FOR EACH STATEMENT EXECUTE FUNCTION private.invalidate_staff_attention('incidents');
-- Re-enabling never resurrects an old count as current.
CREATE FUNCTION private.invalidate_incident_attention() RETURNS TRIGGER
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.enabled IS DISTINCT FROM OLD.enabled OR NEW.audience_roles IS DISTINCT FROM OLD.audience_roles THEN
  UPDATE private.staff_attention_snapshots SET invalidated=true WHERE queue_key='incidents';
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.invalidate_incident_attention() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER incident_attention_rollout AFTER UPDATE OF enabled,audience_roles ON private.incident_control
 FOR EACH ROW EXECUTE FUNCTION private.invalidate_incident_attention();

CREATE OR REPLACE FUNCTION private.refresh_staff_attention()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE key TEXT; seen BIGINT[]; n BIGINT;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtextextended('staff-attention-refresh',0)) THEN RETURN; END IF;
  FOREACH key IN ARRAY ARRAY['appeals','legal','moderation','support','incidents'] LOOP
    -- Capture visible, committed markers BEFORE counting. Any later/uncommitted
    -- source change retains its marker, even if its transaction ID is lower.
    -- Bound cleanup; remaining backlog conservatively keeps the count stale.
    SELECT array_agg(transaction_id) INTO seen FROM (
      SELECT transaction_id FROM private.staff_attention_changes WHERE queue_key=key
      ORDER BY transaction_id LIMIT 1000) pending;
    SELECT CASE key
      WHEN 'incidents' THEN (SELECT count(*) FROM (SELECT 1 FROM private.operational_incidents WHERE status NOT IN ('resolved','reviewed') LIMIT 100) bounded)
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
    (s.queue_key='incidents' AND private.incident_pilot_member(actor)) OR
    (s.queue_key='support' AND public.is_staff(actor,ARRAY['super_admin','admin','support'])) OR
    (s.queue_key='legal' AND public.is_staff(actor,ARRAY['super_admin'])) OR
    (s.queue_key IN ('moderation','appeals') AND public.is_staff(actor,ARRAY['super_admin','admin','moderator']));
  IF control.job_events_enabled AND public.is_staff(actor,ARRAY['super_admin','admin']) THEN
    queues:=queues||jsonb_build_array((SELECT jsonb_build_object('key','jobs','count',least(COALESCE(sum(observed_count),0),100),
      'measured_at',COALESCE(min(measured_at),'epoch'::TIMESTAMPTZ),
      'stale',count(measured_at)<>3 OR min(measured_at)<now()-interval '2 minutes' OR max(measured_at)>now()+interval '1 minute')
      FROM private.staff_job_attention));
  END IF;
  RETURN jsonb_build_object('enabled',true,'unread_count',LEAST(unread,99),'unread_more',unread>99,
    'generated_at',now(),'worker_at',control.worker_at,'queues',queues);
END;
$$;
-- CREATE OR REPLACE preserves the previous explicit ACLs.
SELECT public.record_migration('20261029090012','incident_pilot_attention');
NOTIFY pgrst,'reload schema';
