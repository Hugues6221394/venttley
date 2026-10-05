-- Staff access review ledger. Ships disabled (access_review_control.enabled).
-- Must run AFTER 20261029090000_operational_governance_workflows.
-- No Auth writes or privilege changes: revoke_required is work, not revocation.
BEGIN;

CREATE TABLE private.access_review_control (
  singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK (singleton),
  enabled BOOLEAN NOT NULL DEFAULT false
);
INSERT INTO private.access_review_control DEFAULT VALUES;
CREATE TABLE private.access_review_campaigns (
  campaign_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  period DATE NOT NULL UNIQUE CHECK (extract(day FROM period)=1),
  due_at TIMESTAMPTZ NOT NULL,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  closed_at TIMESTAMPTZ,
  version BIGINT NOT NULL DEFAULT 1 CHECK (version>0)
);
CREATE TABLE private.access_review_items (
  campaign_id UUID NOT NULL REFERENCES private.access_review_campaigns,
  subject_id UUID NOT NULL,
  reviewer_id UUID NOT NULL,
  role_snapshot TEXT NOT NULL,
  status_snapshot TEXT NOT NULL,
  deactivated_snapshot TIMESTAMPTZ,
  decision TEXT NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending','retained','revoke_required','revoked')),
  reason_code TEXT CHECK (reason_code IN ('business_need','no_business_need','inactive_access','role_mismatch','revocation_verified','scope_changed')),
  valid_until TIMESTAMPTZ,
  decided_by UUID,
  decided_at TIMESTAMPTZ,
  version BIGINT NOT NULL DEFAULT 1 CHECK (version>0),
  PRIMARY KEY (campaign_id,subject_id),
  CHECK (reviewer_id<>subject_id),
  CHECK ((decision='retained')=(valid_until IS NOT NULL))
);
CREATE TABLE private.access_review_events (
  event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  campaign_id UUID NOT NULL REFERENCES private.access_review_campaigns,
  subject_id UUID,
  actor_id UUID NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('created','retain','require_revocation','confirm_revoked','refresh','reassign','closed')),
  reason_code TEXT,
  detail JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(detail)='object'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX access_review_campaign_created ON private.access_review_campaigns(created_at DESC,campaign_id DESC);
CREATE INDEX access_review_event_cursor ON private.access_review_events(campaign_id,event_id DESC);
ALTER TABLE private.access_review_control ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.access_review_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.access_review_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.access_review_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.access_review_control,private.access_review_campaigns,private.access_review_items,private.access_review_events FROM PUBLIC,anon,authenticated;
REVOKE ALL ON SEQUENCE private.access_review_events_event_id_seq FROM PUBLIC,anon,authenticated;
CREATE TRIGGER access_review_events_immutable BEFORE UPDATE OR DELETE ON private.access_review_events
FOR EACH ROW EXECUTE FUNCTION private.immutable_operational_record();

CREATE FUNCTION private.require_access_reviewer(p_mutation BOOLEAN DEFAULT false) RETURNS VOID
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(),ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF p_mutation THEN PERFORM private.require_aal2(); END IF;
  IF NOT EXISTS (SELECT 1 FROM private.access_review_control WHERE enabled) THEN RAISE EXCEPTION 'access_reviews_disabled' USING ERRCODE='42501'; END IF;
END $$;
REVOKE ALL ON FUNCTION private.require_access_reviewer(BOOLEAN) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.admin_configure_access_reviews(p_operation UUID,p_enabled BOOLEAN) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); request JSONB:=jsonb_build_object('enabled',p_enabled);
BEGIN
  IF NOT public.is_staff(actor,ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  PERFORM private.require_aal2();
  IF p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
  IF private.admin_operation_existing(actor,p_operation,'access_review.configure',request) IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('access_review_configure',3600,20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  UPDATE private.access_review_control SET enabled=p_enabled;
  PERFORM private.record_admin_operation(actor,p_operation,'access_review.configure',request,p_operation);
  PERFORM private.record_operational_audit(actor,'access_review_configured','access_review_control',NULL,'access reviews','Changed access-review availability.',request);
END $$;

CREATE FUNCTION public.admin_create_access_review(p_operation UUID,p_period DATE,p_due_at TIMESTAMPTZ) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); result UUID; alternate UUID; amount INT;
  request JSONB:=jsonb_build_object('period',p_period,'due_at',p_due_at);
BEGIN
  PERFORM private.require_access_reviewer(true);
  result:=private.admin_operation_existing(actor,p_operation,'access_review.create',request);
  IF result IS NOT NULL THEN RETURN result; END IF;
  IF p_period IS NULL OR extract(day FROM p_period)<>1 OR p_due_at IS NULL OR p_due_at<=now() OR p_due_at>now()+interval '90 days' THEN RAISE EXCEPTION 'invalid_input'; END IF;
  IF NOT public.claim_rate_limit('access_review_create',3600,10) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT u.user_id INTO alternate FROM public.users u WHERE u.user_role='super_admin' AND u.user_id<>actor
    AND u.account_status='active' AND u.deactivated_at IS NULL ORDER BY u.user_id LIMIT 1;
  IF alternate IS NULL THEN RAISE EXCEPTION 'independent_reviewer_required'; END IF;
  INSERT INTO private.access_review_campaigns(period,due_at,created_by) VALUES(p_period,p_due_at,actor) ON CONFLICT(period) DO NOTHING RETURNING campaign_id INTO result;
  IF result IS NULL THEN RAISE EXCEPTION 'review_period_exists'; END IF;
  -- One MVCC statement defines membership; never certify a truncated scan.
  INSERT INTO private.access_review_items(campaign_id,subject_id,reviewer_id,role_snapshot,status_snapshot,deactivated_snapshot)
  SELECT result,u.user_id,CASE WHEN u.user_id=actor THEN alternate ELSE actor END,u.user_role::TEXT,u.account_status::TEXT,u.deactivated_at
    FROM public.users u WHERE u.user_role IN ('super_admin','admin','moderator','support','analyst','read_only_auditor')
    ORDER BY u.user_id LIMIT 501;
  GET DIAGNOSTICS amount=ROW_COUNT;
  IF amount>500 THEN RAISE EXCEPTION 'review_scope_exceeds_limit'; END IF;
  INSERT INTO private.access_review_events(campaign_id,actor_id,kind) VALUES(result,actor,'created');
  PERFORM private.record_admin_operation(actor,p_operation,'access_review.create',request,result);
  PERFORM private.record_operational_audit(actor,'access_review_created','access_review',result,'staff review','Created a frozen staff access-review scope.',jsonb_build_object('subjects',amount,'period',p_period));
  RETURN result;
END $$;

CREATE FUNCTION public.admin_access_review_command(p_operation UUID,p_campaign UUID,p_subject UUID,p_version BIGINT,p_command TEXT,p_reason TEXT DEFAULT NULL,p_valid_until TIMESTAMPTZ DEFAULT NULL,p_reviewer UUID DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); c private.access_review_campaigns%ROWTYPE; i private.access_review_items%ROWTYPE; u public.users%ROWTYPE;
  request JSONB:=jsonb_build_object('campaign',p_campaign,'subject',p_subject,'version',p_version,'command',p_command,'reason',p_reason,'valid_until',p_valid_until,'reviewer',p_reviewer);
BEGIN
  PERFORM private.require_access_reviewer(true);
  IF private.admin_operation_existing(actor,p_operation,'access_review.command',request) IS NOT NULL THEN RETURN; END IF;
  IF p_command IS NULL OR p_command NOT IN ('retain','require_revocation','confirm_revoked','refresh','reassign','close') OR p_version IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
  IF NOT public.claim_rate_limit('access_review_command',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  -- Campaign before item, for every command. Closing cannot race a decision.
  SELECT * INTO c FROM private.access_review_campaigns WHERE campaign_id=p_campaign FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
  IF c.closed_at IS NOT NULL THEN RAISE EXCEPTION 'review_closed'; END IF;
  IF p_command='close' THEN
    IF p_subject IS NOT NULL OR p_reason IS NOT NULL OR p_valid_until IS NOT NULL OR p_reviewer IS NOT NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
    IF c.version<>p_version THEN RAISE EXCEPTION 'review_conflict'; END IF;
    IF EXISTS (SELECT 1 FROM private.access_review_items x LEFT JOIN public.users s ON s.user_id=x.subject_id
      WHERE x.campaign_id=p_campaign AND (x.decision IN ('pending','revoke_required') OR
      (x.decision='retained' AND (x.valid_until<=now() OR s.user_id IS NULL OR s.user_role::TEXT IS DISTINCT FROM x.role_snapshot OR s.account_status::TEXT IS DISTINCT FROM x.status_snapshot OR s.deactivated_at IS DISTINCT FROM x.deactivated_snapshot)) OR
      (x.decision='revoked' AND s.user_role IN ('super_admin','admin','moderator','support','analyst','read_only_auditor')))) THEN RAISE EXCEPTION 'review_incomplete'; END IF;
    UPDATE private.access_review_campaigns SET closed_at=now(),version=version+1 WHERE campaign_id=p_campaign;
  ELSE
    SELECT * INTO i FROM private.access_review_items WHERE campaign_id=p_campaign AND subject_id=p_subject FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
    IF i.version<>p_version THEN RAISE EXCEPTION 'review_conflict'; END IF;
    IF actor=p_subject THEN RAISE EXCEPTION 'independent_reviewer_required'; END IF;
    IF p_command='reassign' THEN
      IF p_reviewer IS NULL OR p_reviewer=p_subject OR NOT public.is_staff(p_reviewer,ARRAY['super_admin']) OR p_reason IS NOT NULL OR p_valid_until IS NOT NULL THEN RAISE EXCEPTION 'invalid_reviewer'; END IF;
      UPDATE private.access_review_items SET reviewer_id=p_reviewer,version=version+1 WHERE campaign_id=p_campaign AND subject_id=p_subject;
    ELSE
      IF i.reviewer_id<>actor THEN RAISE EXCEPTION 'reviewer_not_assigned'; END IF;
      IF p_reviewer IS NOT NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
      SELECT * INTO u FROM public.users WHERE user_id=p_subject FOR SHARE;
      IF p_command='confirm_revoked' THEN
        IF p_reason IS DISTINCT FROM 'revocation_verified' OR p_valid_until IS NOT NULL OR (u.user_id IS NOT NULL AND u.user_role IN ('super_admin','admin','moderator','support','analyst','read_only_auditor')) THEN RAISE EXCEPTION 'revocation_not_verified'; END IF;
        UPDATE private.access_review_items SET decision='revoked',reason_code=p_reason,valid_until=NULL,decided_by=actor,decided_at=now(),version=version+1 WHERE campaign_id=p_campaign AND subject_id=p_subject;
      ELSIF p_command='refresh' THEN
        IF p_reason IS DISTINCT FROM 'scope_changed' OR p_valid_until IS NOT NULL OR u.user_id IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
        UPDATE private.access_review_items SET role_snapshot=u.user_role::TEXT,status_snapshot=u.account_status::TEXT,deactivated_snapshot=u.deactivated_at,decision='pending',reason_code=p_reason,valid_until=NULL,decided_by=NULL,decided_at=NULL,version=version+1 WHERE campaign_id=p_campaign AND subject_id=p_subject;
      ELSE
        IF u.user_id IS NULL OR u.user_role::TEXT IS DISTINCT FROM i.role_snapshot OR u.account_status::TEXT IS DISTINCT FROM i.status_snapshot OR u.deactivated_at IS DISTINCT FROM i.deactivated_snapshot THEN RAISE EXCEPTION 'review_scope_changed'; END IF;
        IF p_command='retain' THEN
          IF p_reason IS DISTINCT FROM 'business_need' OR p_valid_until IS NULL OR p_valid_until<=now() OR p_valid_until>now()+interval '90 days' OR u.account_status<>'active' OR u.deactivated_at IS NOT NULL OR u.user_role NOT IN ('super_admin','admin','moderator','support','analyst','read_only_auditor') THEN RAISE EXCEPTION 'invalid_attestation'; END IF;
        ELSIF p_reason IS NULL OR p_reason NOT IN ('no_business_need','inactive_access','role_mismatch') OR p_valid_until IS NOT NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
        UPDATE private.access_review_items SET decision=CASE WHEN p_command='retain' THEN 'retained' ELSE 'revoke_required' END,reason_code=p_reason,valid_until=p_valid_until,decided_by=actor,decided_at=now(),version=version+1 WHERE campaign_id=p_campaign AND subject_id=p_subject;
      END IF;
    END IF;
    UPDATE private.access_review_campaigns SET version=version+1 WHERE campaign_id=p_campaign;
  END IF;
  INSERT INTO private.access_review_events(campaign_id,subject_id,actor_id,kind,reason_code,detail)
  VALUES(p_campaign,p_subject,actor,CASE WHEN p_command='close' THEN 'closed' ELSE p_command END,p_reason,
    jsonb_build_object('previous_version',p_version,'previous_decision',i.decision,'previous_role',i.role_snapshot,
      'previous_reviewer',i.reviewer_id,'assigned_reviewer',p_reviewer,'valid_until',p_valid_until,
      'refreshed_role',CASE WHEN p_command='refresh' THEN u.user_role::TEXT END));
  PERFORM private.record_admin_operation(actor,p_operation,'access_review.command',request,p_campaign);
  PERFORM private.record_operational_audit(actor,'access_review_updated','access_review',p_campaign,'staff review','Recorded an access-review command.',jsonb_build_object('command',p_command,'reason_code',p_reason));
END $$;

CREATE FUNCTION public.admin_access_review_register(p_campaign UUID DEFAULT NULL,p_after UUID DEFAULT NULL,p_before DATE DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c private.access_review_campaigns%ROWTYPE; result JSONB; totals JSONB;
BEGIN
  IF NOT public.is_staff(auth.uid(),ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF NOT public.claim_rate_limit('access_review_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF NOT EXISTS (SELECT 1 FROM private.access_review_control WHERE enabled) THEN RETURN jsonb_build_object('enabled',false); END IF;
  IF p_campaign IS NULL THEN
    RETURN jsonb_build_object('enabled',true,'measured_at',now(),'campaigns',(SELECT COALESCE(jsonb_agg(to_jsonb(x)),'[]'::JSONB) FROM
      (SELECT campaign_id,period,due_at,closed_at,version FROM private.access_review_campaigns WHERE p_before IS NULL OR period<p_before ORDER BY period DESC LIMIT 26)x));
  END IF;
  SELECT * INTO c FROM private.access_review_campaigns WHERE campaign_id=p_campaign;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
  SELECT jsonb_build_object('total',count(*),'pending',count(*) FILTER(WHERE x.decision='pending'),'revocation_required',count(*) FILTER(WHERE x.decision='revoke_required'),'expired',count(*) FILTER(WHERE x.decision='retained' AND x.valid_until<=now()),
    'changed',count(*) FILTER(WHERE s.user_id IS NULL OR s.user_role::TEXT IS DISTINCT FROM x.role_snapshot OR s.account_status::TEXT IS DISTINCT FROM x.status_snapshot OR s.deactivated_at IS DISTINCT FROM x.deactivated_snapshot))
    INTO totals FROM private.access_review_items x LEFT JOIN public.users s ON s.user_id=x.subject_id WHERE x.campaign_id=p_campaign;
  SELECT COALESCE(jsonb_agg(to_jsonb(x)),'[]'::JSONB) INTO result FROM (
    SELECT i.subject_id,i.reviewer_id,i.role_snapshot,i.status_snapshot,i.decision,i.reason_code,i.valid_until,i.version,
      COALESCE(s.display_name,'Former staff member') AS subject_name,COALESCE(r.display_name,'Former reviewer') AS reviewer_name,
      i.reviewer_id=auth.uid() AS assigned_to_me,
      i.subject_id=auth.uid() AS is_self,
      (s.user_id IS NULL OR s.user_role::TEXT IS DISTINCT FROM i.role_snapshot OR s.account_status::TEXT IS DISTINCT FROM i.status_snapshot OR s.deactivated_at IS DISTINCT FROM i.deactivated_snapshot) AS scope_changed
    FROM private.access_review_items i LEFT JOIN public.users s ON s.user_id=i.subject_id LEFT JOIN public.users r ON r.user_id=i.reviewer_id
    WHERE i.campaign_id=p_campaign AND (p_after IS NULL OR i.subject_id>p_after) ORDER BY i.subject_id LIMIT 26)x;
  RETURN jsonb_build_object('enabled',true,'measured_at',now(),'campaign',jsonb_build_object('campaign_id',c.campaign_id,'period',c.period,'due_at',c.due_at,'closed_at',c.closed_at,'version',c.version),'totals',totals,'items',result,
    'events',(SELECT COALESCE(jsonb_agg(to_jsonb(e)),'[]'::JSONB) FROM (SELECT e.event_id,e.kind,e.reason_code,e.created_at,COALESCE(a.display_name,'Former operator') AS actor_name,COALESCE(s.display_name,'Campaign') AS subject_name
      FROM private.access_review_events e LEFT JOIN public.users a ON a.user_id=e.actor_id LEFT JOIN public.users s ON s.user_id=e.subject_id WHERE e.campaign_id=p_campaign ORDER BY e.event_id DESC LIMIT 20)e));
END $$;

CREATE FUNCTION public.admin_access_review_reviewers() RETURNS TABLE(staff_id UUID,display_name TEXT,username TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  PERFORM private.require_access_reviewer();
  IF NOT public.claim_rate_limit('access_review_reviewers',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  RETURN QUERY SELECT u.user_id,u.display_name,u.anonymous_pseudonym::TEXT FROM public.users u WHERE u.user_role='super_admin' AND u.account_status='active' AND u.deactivated_at IS NULL ORDER BY u.user_id LIMIT 100;
END $$;
REVOKE ALL ON FUNCTION public.admin_configure_access_reviews(UUID,BOOLEAN),public.admin_create_access_review(UUID,DATE,TIMESTAMPTZ),public.admin_access_review_command(UUID,UUID,UUID,BIGINT,TEXT,TEXT,TIMESTAMPTZ,UUID),public.admin_access_review_register(UUID,UUID,DATE),public.admin_access_review_reviewers() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_configure_access_reviews(UUID,BOOLEAN),public.admin_create_access_review(UUID,DATE,TIMESTAMPTZ),public.admin_access_review_command(UUID,UUID,UUID,BIGINT,TEXT,TEXT,TIMESTAMPTZ,UUID),public.admin_access_review_register(UUID,UUID,DATE),public.admin_access_review_reviewers() TO authenticated;
COMMIT;

-- Every migration records itself, so the app can tell a database that is
-- behind the build from one that is current. Added after the fact: this file
-- shipped without it, and the copy already applied to production is
-- back-filled by 20261075090000_the_ledger_catches_up.sql.
SELECT public.record_migration('20261067090000', 'access_review_ledger');
