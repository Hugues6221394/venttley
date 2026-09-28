-- CLI-created 20260927132253; follows this branch's future-dated dependencies.
-- Internal coordination only. No evidence, containment or external paging.
CREATE TABLE private.incident_control(singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK(singleton),enabled BOOLEAN NOT NULL DEFAULT false);
INSERT INTO private.incident_control DEFAULT VALUES;
CREATE TABLE private.operational_incidents (
 incident_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 number BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
 title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 120 AND title !~ '[[:cntrl:]<>]'),
 severity TEXT NOT NULL CHECK(severity IN ('sev1','sev2','sev3','sev4')),
 status TEXT NOT NULL DEFAULT 'declared' CHECK(status IN ('declared','investigating','mitigating','monitoring','resolved','reviewed')),
 services TEXT[] NOT NULL CHECK(cardinality(services) BETWEEN 1 AND 8 AND services <@ ARRAY['auth','feed','chat','moderation','media','push','email','database']::TEXT[] AND array_position(services,NULL) IS NULL),
 commander UUID NOT NULL, -- Historical staff identifiers deliberately survive account deletion.
 responders UUID[] NOT NULL DEFAULT '{}' CHECK(cardinality(responders)<=20 AND array_position(responders,NULL) IS NULL),
 response_due_at TIMESTAMPTZ NOT NULL CHECK(isfinite(response_due_at)),
 runbook TEXT NOT NULL CHECK(runbook IN ('system','delivery','media','recovery','moderation')),
 signal TEXT CHECK(signal IN ('crisis-posts','moderation-sla','push-dead','email-failed','media-stale')),
 version BIGINT NOT NULL DEFAULT 1 CHECK(version>0),
 created_by UUID NOT NULL,created_at TIMESTAMPTZ NOT NULL DEFAULT now(),updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX operational_incidents_queue ON private.operational_incidents(created_at DESC,incident_id DESC);
CREATE INDEX operational_incidents_active_due ON private.operational_incidents(response_due_at,incident_id) WHERE status NOT IN ('resolved','reviewed');
CREATE INDEX operational_incidents_review ON private.operational_incidents(created_at,incident_id) WHERE status='resolved';
CREATE TABLE private.incident_events (
 event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 incident_id UUID NOT NULL REFERENCES private.operational_incidents(incident_id),
 version BIGINT NOT NULL,actor_id UUID NOT NULL,kind TEXT NOT NULL,
 note TEXT NOT NULL DEFAULT '' CHECK(length(note)<=2000 AND note !~ '[<>]' AND note !~ '[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]'),
 detail JSONB NOT NULL DEFAULT '{}',created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(incident_id,version)
);
CREATE TABLE private.incident_actions (
 action_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),incident_id UUID NOT NULL REFERENCES private.operational_incidents(incident_id),
 title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 160 AND title !~ '[[:cntrl:]<>]'),
 owner_id UUID NOT NULL,due_at TIMESTAMPTZ NOT NULL CHECK(isfinite(due_at)),completed_at TIMESTAMPTZ,created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX incident_actions_incident ON private.incident_actions(incident_id,created_at,action_id);
ALTER TABLE private.incident_control ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.operational_incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.incident_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.incident_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.incident_control,private.operational_incidents,private.incident_events,private.incident_actions FROM PUBLIC,anon,authenticated;
CREATE TRIGGER incident_events_immutable BEFORE UPDATE OR DELETE ON private.incident_events FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();

CREATE FUNCTION public.admin_configure_incidents(p_operation UUID,p_enabled BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); request JSONB:=jsonb_build_object('enabled',p_enabled);
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 IF p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_rollout' USING ERRCODE='22023'; END IF;
 IF private.admin_operation_existing(actor,p_operation,'incident.configure',request) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('incident_configure',60,10) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 UPDATE private.incident_control SET enabled=p_enabled WHERE singleton;
 PERFORM private.record_operational_audit(actor,'incident.configure','incident_control',p_operation,'Incident coordination','release_control',request);
 PERFORM private.record_admin_operation(actor,p_operation,'incident.configure',request,p_operation);
END $$;

CREATE FUNCTION public.admin_incident_staff(p_query TEXT DEFAULT '')
RETURNS TABLE(staff_id UUID,display_name TEXT) LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF NOT (SELECT enabled FROM private.incident_control WHERE singleton) THEN RETURN; END IF;
 IF p_query IS NULL OR length(p_query)>50 THEN RAISE EXCEPTION 'invalid_query' USING ERRCODE='22023'; END IF;
 IF NOT public.claim_rate_limit('incident_staff',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 RETURN QUERY SELECT u.user_id,u.display_name FROM public.users u WHERE u.user_role<>'normal' AND u.user_role IN ('super_admin','admin')
 AND public.is_staff(u.user_id,ARRAY['super_admin','admin']) AND (p_query='' OR starts_with(lower(u.display_name),lower(btrim(p_query)))) ORDER BY u.display_name,u.user_id LIMIT 25;
END $$;

CREATE FUNCTION public.admin_incident_mutate(p_operation UUID,p_incident UUID,p_version BIGINT,p_command TEXT,p_payload JSONB)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
<<mutation>>
DECLARE actor UUID:=auth.uid(); request JSONB; result UUID; i private.operational_incidents; allowed TEXT[]; note TEXT; command_owner UUID;
 services TEXT[]; responders UUID[]; due TIMESTAMPTZ; new_status TEXT; event_detail JSONB:='{}'; action_id UUID;
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 -- Configuration takes an exclusive lock; rollback waits for bounded writes.
 PERFORM 1 FROM private.incident_control WHERE singleton AND enabled FOR SHARE;
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
  IF command_owner IS NULL OR NOT public.is_staff(command_owner,ARRAY['super_admin','admin']) OR cardinality(responders)>20 OR
   EXISTS(SELECT 1 FROM unnest(responders)u WHERE u IS NULL OR NOT public.is_staff(u,ARRAY['super_admin','admin'])) THEN RAISE EXCEPTION 'invalid_staff' USING ERRCODE='22023'; END IF;
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
  IF command_owner IS NULL OR NOT public.is_staff(command_owner,ARRAY['super_admin','admin']) OR due IS NULL OR NOT isfinite(due) OR due<=now() OR due>now()+interval '365 days' THEN RAISE EXCEPTION 'invalid_action_owner_or_deadline' USING ERRCODE='22023'; END IF;
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

CREATE FUNCTION public.admin_incident_queue(p_filter TEXT DEFAULT 'active',p_severity TEXT DEFAULT 'all',p_before_at TIMESTAMPTZ DEFAULT NULL,p_before_id UUID DEFAULT NULL,p_limit INTEGER DEFAULT 31)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); rows JSONB; active_count INTEGER; overdue_count INTEGER; review_count INTEGER;
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF p_filter IS NULL OR p_filter NOT IN ('active','mine','all','review') OR p_severity IS NULL OR p_severity NOT IN ('all','sev1','sev2','sev3','sev4') OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 51 OR (p_before_at IS NULL)<>(p_before_id IS NULL) OR (p_before_at IS NOT NULL AND NOT isfinite(p_before_at)) THEN RAISE EXCEPTION 'invalid_queue' USING ERRCODE='22023'; END IF;
 IF NOT public.claim_rate_limit('incident_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF NOT (SELECT enabled FROM private.incident_control WHERE singleton) THEN RETURN jsonb_build_object('enabled',false); END IF;
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
CREATE FUNCTION public.admin_incident_detail(p_incident UUID,p_before_version BIGINT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE incident JSONB; events JSONB; actions JSONB;
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 IF NOT public.claim_rate_limit('incident_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF NOT (SELECT enabled FROM private.incident_control WHERE singleton) THEN RETURN jsonb_build_object('enabled',false); END IF;
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
REVOKE ALL ON FUNCTION public.admin_configure_incidents(UUID,BOOLEAN),public.admin_incident_staff(TEXT),public.admin_incident_mutate(UUID,UUID,BIGINT,TEXT,JSONB),public.admin_incident_queue(TEXT,TEXT,TIMESTAMPTZ,UUID,INTEGER),public.admin_incident_detail(UUID,BIGINT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_configure_incidents(UUID,BOOLEAN),public.admin_incident_staff(TEXT),public.admin_incident_mutate(UUID,UUID,BIGINT,TEXT,JSONB),public.admin_incident_queue(TEXT,TEXT,TIMESTAMPTZ,UUID,INTEGER),public.admin_incident_detail(UUID,BIGINT) TO authenticated;
SELECT public.record_migration('20261029090010','incident_command');
NOTIFY pgrst,'reload schema';
