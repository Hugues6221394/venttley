-- CLI-created 20260926084433; ordered after the existing future-dated dependencies.
-- Additive keyset queues. No truncated legacy RPC is paginated after its LIMIT.
CREATE INDEX IF NOT EXISTS moderation_cases_work_cursor_idx ON public.moderation_cases((COALESCE(sla_due_at,'9999-12-31 UTC'::timestamptz)),case_id);
CREATE INDEX IF NOT EXISTS moderation_appeals_work_cursor_idx ON public.moderation_appeals(created_at,appeal_id);
CREATE INDEX IF NOT EXISTS support_event_work_cursor_idx ON private.support_case_events(support_case_id,created_at DESC,event_id DESC);
CREATE OR REPLACE FUNCTION public.admin_case_work_queue(
    p_status   TEXT DEFAULT NULL,
    p_assignee UUID DEFAULT NULL,
    p_limit    INT DEFAULT 31,
    p_cursor JSONB DEFAULT NULL
) RETURNS TABLE (
    case_id        UUID,
    target_type    TEXT,
    target_id      UUID,
    subject_id     UUID,
    subject_pseudonym TEXT,
    status         TEXT,
    severity       TEXT,
    assignee_id    UUID,
    assignee_pseudonym TEXT,
    report_count   INT,
    sla_due_at     TIMESTAMPTZ,
    sla_breached   BOOLEAN,
    minutes_to_due NUMERIC,
    legal_hold     BOOLEAN,
    opened_at      TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    _cursor JSONB
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF NOT public.is_staff(auth.uid(), ARRAY['super_admin','admin','moderator','support']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;


  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 51 THEN RAISE EXCEPTION 'invalid_queue' USING ERRCODE='22023'; END IF;
  IF p_cursor IS NOT NULL AND (jsonb_typeof(p_cursor)<>'object'
    OR NOT (p_cursor ?& ARRAY['a','b','t','k','i'])
    OR (p_cursor->>'a') IS NULL OR (p_cursor->>'b') IS NULL
    OR (p_cursor->>'k') IS NULL OR (p_cursor->>'i') IS NULL
    OR (p_cursor->>'t') IS NULL OR NOT isfinite((p_cursor->>'t')::timestamptz)
    OR length(p_cursor::text)>512) THEN RAISE EXCEPTION 'invalid_cursor' USING ERRCODE='22023'; END IF;
  IF NOT public.claim_rate_limit('daily_work_queue',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;

  IF p_status IS NOT NULL AND p_status NOT IN ('unresolved','resolved','open','in_review','awaiting_second_review','escalated','reopened') THEN RAISE EXCEPTION 'invalid_queue' USING ERRCODE='22023'; END IF;
    RETURN QUERY
    SELECT c.case_id, c.target_type, c.target_id, c.subject_id,
           su.anonymous_pseudonym::text, c.status, c.severity,
           c.assignee_id, au.anonymous_pseudonym::text, c.report_count,
           c.sla_due_at,
           (c.sla_breached_at IS NOT NULL
            OR (c.status <> 'resolved' AND c.sla_due_at < now())) AS sla_breached,
           round(EXTRACT(EPOCH FROM (c.sla_due_at - now())) / 60.0, 1),
           c.legal_hold, c.opened_at, c.updated_at,
           jsonb_build_object('a',0,'b',0,'t',COALESCE(c.sla_due_at,'9999-12-31 UTC'::timestamptz),'k','','i',c.case_id)
      FROM public.moderation_cases c
      LEFT JOIN public.users su ON su.user_id = c.subject_id
      LEFT JOIN public.users au ON au.user_id = c.assignee_id
     WHERE (p_status IS NULL
            OR (p_status = 'unresolved' AND c.status <> 'resolved')
            OR c.status = p_status)
       AND (p_assignee IS NULL OR c.assignee_id = p_assignee)

       AND (p_cursor IS NULL OR (COALESCE(c.sla_due_at,'9999-12-31 UTC'::timestamptz),c.case_id)>((p_cursor->>'t')::timestamptz,(p_cursor->>'i')::uuid))
     ORDER BY COALESCE(c.sla_due_at,'9999-12-31 UTC'::timestamptz),c.case_id LIMIT p_limit;
END $$;

CREATE OR REPLACE FUNCTION public.admin_appeal_work_queue(
    p_status TEXT DEFAULT 'open',
    p_limit  INT DEFAULT 31,
    p_cursor JSONB DEFAULT NULL
) RETURNS TABLE (
    appeal_id          UUID,
    case_id            UUID,
    subject_kind       TEXT,
    appellant_id       UUID,
    appellant_pseudonym TEXT,
    statement          TEXT,
    status             TEXT,
    target_type        TEXT,
    original_decision  TEXT,
    original_policy    TEXT,
    original_note      TEXT,
    original_decider   UUID,
    original_decider_pseudonym TEXT,
    decided_at         TIMESTAMPTZ,
    reviewable_by_me   BOOLEAN,
    created_at         TIMESTAMPTZ,
    _cursor JSONB
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF NOT public.is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;


  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 51 THEN RAISE EXCEPTION 'invalid_queue' USING ERRCODE='22023'; END IF;
  IF p_cursor IS NOT NULL AND (jsonb_typeof(p_cursor)<>'object'
    OR NOT (p_cursor ?& ARRAY['a','b','t','k','i'])
    OR (p_cursor->>'a') IS NULL OR (p_cursor->>'b') IS NULL
    OR (p_cursor->>'k') IS NULL OR (p_cursor->>'i') IS NULL
    OR (p_cursor->>'t') IS NULL OR NOT isfinite((p_cursor->>'t')::timestamptz)
    OR length(p_cursor::text)>512) THEN RAISE EXCEPTION 'invalid_cursor' USING ERRCODE='22023'; END IF;
  IF NOT public.claim_rate_limit('daily_work_queue',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;

  IF p_status IS NOT NULL AND p_status NOT IN ('open','upheld','overturned') THEN RAISE EXCEPTION 'invalid_queue' USING ERRCODE='22023'; END IF;
    RETURN QUERY
    SELECT a.appeal_id,
           a.case_id,
           CASE WHEN a.case_id IS NOT NULL THEN 'case'
                WHEN a.verification_request_id IS NOT NULL THEN 'verification'
                ELSE 'account' END::TEXT,
           a.appellant_id, ap.anonymous_pseudonym::text,
           a.statement, a.status,
           COALESCE(c.target_type,
                    CASE WHEN a.verification_request_id IS NOT NULL
                         THEN 'verification_request' ELSE 'account' END)::TEXT,
           -- For an account appeal the decision is the action the member was
           -- told about, which is the only description of it that exists
           -- outside the audit log.
           -- r.status is deliberately not used: overturning reopens the
           -- application, so reading it back would report the appeal as being
           -- about a pending request rather than the refusal it contests.
           COALESCE(c.decision, n.payload->>'action',
                    CASE WHEN r.request_id IS NOT NULL THEN 'verification_denied' END)::TEXT,
           COALESCE(c.policy_code, n.payload->>'policy')::TEXT,
           COALESCE(c.decision_note, n.payload->>'reason', r.review_reason)::TEXT,
           v_decider.user_id,
           v_decider.anonymous_pseudonym::text,
           COALESCE(c.decided_at, a.original_decided_at,
                    (n.payload->>'decided_at')::TIMESTAMPTZ, r.reviewed_at),
           -- Surfaced so the console can hide the controls rather than let a
           -- moderator submit a review the RPC will refuse.
           (COALESCE(c.decided_by, r.reviewed_by, a.original_decider_id)
              IS DISTINCT FROM auth.uid()
            AND a.appellant_id IS DISTINCT FROM auth.uid()) AS reviewable_by_me,
           a.created_at,
           jsonb_build_object('a',0,'b',0,'t',a.created_at,'k','','i',a.appeal_id)
      FROM public.moderation_appeals a
      JOIN public.users ap ON ap.user_id = a.appellant_id
      LEFT JOIN public.moderation_cases c ON c.case_id = a.case_id
      LEFT JOIN public.notifications n ON n.notification_id = a.enforcement_notification_id
      LEFT JOIN public.verification_requests r ON r.request_id = a.verification_request_id
      LEFT JOIN public.users v_decider
             ON v_decider.user_id = COALESCE(c.decided_by, r.reviewed_by,
                                             a.original_decider_id)
     WHERE (p_status IS NULL OR a.status = p_status)

       AND (p_cursor IS NULL OR (a.created_at,a.appeal_id)>((p_cursor->>'t')::timestamptz,(p_cursor->>'i')::uuid))
     ORDER BY a.created_at,a.appeal_id LIMIT p_limit;
END $$;

CREATE OR REPLACE FUNCTION public.admin_safety_work_queue(
  p_include_resolved BOOLEAN DEFAULT FALSE,
  p_limit INT DEFAULT 31,
  p_cursor JSONB DEFAULT NULL
) RETURNS TABLE (
  item_type TEXT,
  severity TEXT,
  severity_rank INT,
  ref_id UUID,
  report_id UUID,
  reason TEXT,
  note TEXT,
  author_id UUID,
  author_pseudonym TEXT,
  preview TEXT,
  is_open BOOLEAN,
  created_at TIMESTAMPTZ,
  _cursor JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_staff(
    auth.uid(), ARRAY['super_admin', 'admin', 'moderator', 'support']
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;


  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 51 THEN RAISE EXCEPTION 'invalid_queue' USING ERRCODE='22023'; END IF;
  IF p_cursor IS NOT NULL AND (jsonb_typeof(p_cursor)<>'object'
    OR NOT (p_cursor ?& ARRAY['a','b','t','k','i'])
    OR (p_cursor->>'a') IS NULL OR (p_cursor->>'b') IS NULL
    OR (p_cursor->>'k') IS NULL OR (p_cursor->>'i') IS NULL
    OR (p_cursor->>'t') IS NULL OR NOT isfinite((p_cursor->>'t')::timestamptz)
    OR length(p_cursor::text)>512) THEN RAISE EXCEPTION 'invalid_cursor' USING ERRCODE='22023'; END IF;
  IF NOT public.claim_rate_limit('daily_work_queue',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;

  RETURN QUERY
  WITH items (
    item_type, severity, severity_rank, ref_id, report_id, reason, note,
    author_id, author_pseudonym, preview, is_open, created_at
  ) AS (
    SELECT 'crisis_post'::TEXT,
           post.crisis_level::TEXT,
           CASE post.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           post.post_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           post.author_id, app_user.anonymous_pseudonym::TEXT,
           left(COALESCE(post.content, ''), 200)::TEXT,
           post.deleted_at IS NULL, post.created_at
      FROM public.posts AS post
      LEFT JOIN public.users AS app_user ON app_user.user_id = post.author_id
     WHERE post.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'crisis_whisper'::TEXT,
           whisper.crisis_level::TEXT,
           CASE whisper.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           whisper.whisper_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           whisper.author_id, app_user.anonymous_pseudonym::TEXT,
           left(
             COALESCE(whisper.title, whisper.description, 'Voice whisper'), 200
           )::TEXT,
           whisper.deleted_at IS NULL, whisper.created_at
      FROM public.whispers AS whisper
      LEFT JOIN public.users AS app_user
        ON app_user.user_id = whisper.author_id
     WHERE whisper.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'crisis_tribe_message'::TEXT,
           message.crisis_level::TEXT,
           CASE message.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           message.message_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           message.sender_id, app_user.anonymous_pseudonym::TEXT,
           left(COALESCE(message.content, ''), 200)::TEXT,
           message.deleted_at IS NULL, message.created_at
      FROM public.tribe_messages AS message
      LEFT JOIN public.users AS app_user
        ON app_user.user_id = message.sender_id
     WHERE message.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'crisis_dm'::TEXT,
           message.crisis_level::TEXT,
           CASE message.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           message.message_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           message.sender_id, app_user.anonymous_pseudonym::TEXT,
           '(private DM - server-readable; access restricted)'::TEXT,
           TRUE, message.created_at
      FROM public.chat_messages AS message
      LEFT JOIN public.users AS app_user
        ON app_user.user_id = message.sender_id
     WHERE message.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'self_harm_report'::TEXT,
           'high'::TEXT,
           3,
           report.report_id,
           report.report_id,
           report.reason::TEXT,
           report.note::TEXT,
           COALESCE(post.author_id, tribe_message.sender_id, dm.sender_id),
           COALESCE(
             post_user.anonymous_pseudonym,
             tribe_user.anonymous_pseudonym,
             dm_user.anonymous_pseudonym
           )::TEXT,
           COALESCE(
             left(post.content, 200),
             left(tribe_message.content, 200),
             CASE WHEN report.target_chat_message_id IS NOT NULL
               THEN '(private DM - server-readable; access restricted)' END,
             CASE WHEN report.target_comment_id IS NOT NULL
               THEN '(reported comment)' END,
             CASE WHEN report.target_room_id IS NOT NULL
               THEN '(reported conversation)' END,
             '(reported content)'
           )::TEXT,
           NOT report.is_resolved,
           report.created_at
      FROM public.reports AS report
      LEFT JOIN public.posts AS post ON post.post_id = report.post_id
      LEFT JOIN public.users AS post_user
        ON post_user.user_id = post.author_id
      LEFT JOIN public.tribe_messages AS tribe_message
        ON tribe_message.message_id = report.target_tribe_message_id
      LEFT JOIN public.users AS tribe_user
        ON tribe_user.user_id = tribe_message.sender_id
      LEFT JOIN public.chat_messages AS dm
        ON dm.message_id = report.target_chat_message_id
      LEFT JOIN public.users AS dm_user ON dm_user.user_id = dm.sender_id
     WHERE report.reason = 'self_harm'
  )
  SELECT item.*, jsonb_build_object('a',CASE WHEN item.is_open THEN 0 ELSE 1 END,'b',-item.severity_rank,'t',item.created_at,'k',item.item_type,'i',item.ref_id)
    FROM items AS item
   WHERE (p_include_resolved OR item.is_open)
   AND (p_cursor IS NULL OR (CASE WHEN item.is_open THEN 0 ELSE 1 END,-item.severity_rank,item.created_at,item.item_type,item.ref_id) > ((p_cursor->>'a')::int,(p_cursor->>'b')::int,(p_cursor->>'t')::timestamptz,p_cursor->>'k',(p_cursor->>'i')::uuid))
   ORDER BY item.is_open DESC, item.severity_rank DESC, item.created_at ASC, item.item_type ASC, item.ref_id ASC
   LIMIT p_limit;
END;
$$;


REVOKE ALL ON FUNCTION public.admin_case_work_queue(TEXT,UUID,INT,JSONB),public.admin_appeal_work_queue(TEXT,INT,JSONB),public.admin_safety_work_queue(BOOLEAN,INT,JSONB) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_case_work_queue(TEXT,UUID,INT,JSONB),public.admin_appeal_work_queue(TEXT,INT,JSONB),public.admin_safety_work_queue(BOOLEAN,INT,JSONB) TO authenticated;

-- Metadata-only history from the immutable canonical ledger. Never return
-- arbitrary JSON details or private member content as a timeline shortcut.
CREATE OR REPLACE FUNCTION public.admin_support_history(
  p_case UUID,p_before_time TIMESTAMPTZ DEFAULT NULL,p_before_id UUID DEFAULT NULL,p_limit INT DEFAULT 31
) RETURNS TABLE(event_id UUID,event_kind TEXT,actor_name TEXT,from_status TEXT,to_status TEXT,priority TEXT,assigned BOOLEAN,created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF p_case IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 51
    OR (p_before_time IS NULL)<>(p_before_id IS NULL)
    OR (p_before_time IS NOT NULL AND NOT isfinite(p_before_time)) THEN RAISE EXCEPTION 'invalid_queue' USING ERRCODE='22023'; END IF;
  IF NOT public.claim_rate_limit('support_history',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF NOT EXISTS(SELECT 1 FROM private.support_cases WHERE support_case_id=p_case) THEN RAISE EXCEPTION 'support_case_not_found' USING ERRCODE='P0002'; END IF;
  RETURN QUERY SELECT e.event_id,e.event_kind,u.display_name::text,e.detail->>'from',e.detail->>'to',e.detail->>'priority',
    CASE WHEN jsonb_typeof(e.detail->'assigned')='boolean' THEN (e.detail->>'assigned')::boolean ELSE NULL END,e.created_at
    FROM private.support_case_events e LEFT JOIN public.users u ON u.user_id=e.actor_id
    WHERE e.support_case_id=p_case AND (p_before_time IS NULL OR (e.created_at,e.event_id)<(p_before_time,p_before_id))
    ORDER BY e.created_at DESC,e.event_id DESC LIMIT p_limit;
END $$;
REVOKE ALL ON FUNCTION public.admin_support_history(UUID,TIMESTAMPTZ,UUID,INT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_support_history(UUID,TIMESTAMPTZ,UUID,INT) TO authenticated;

-- A single checked command boundary for the pilot. Commands delegate to the
-- canonical mutation so independence, sanctions, notifications and audit stay
-- atomic. The receipt stores only a hash, never the supplied review note.
CREATE OR REPLACE FUNCTION public.admin_case_command(
 p_operation UUID,p_case UUID,p_expected_updated_at TIMESTAMPTZ,p_command TEXT,p_value TEXT DEFAULT NULL,p_note TEXT DEFAULT NULL,p_policy TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v public.moderation_cases; req JSONB:=jsonb_build_object('case',p_case,'version',p_expected_updated_at,'command',p_command,'value',p_value,'note',p_note,'policy',p_policy);
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','moderator']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 IF private.admin_operation_existing(auth.uid(),p_operation,'case.command',req) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('case_command',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF p_command IS NULL OR p_command NOT IN ('claim','status','decision') OR length(COALESCE(p_note,''))>1000 OR length(COALESCE(p_policy,''))>60 THEN RAISE EXCEPTION 'invalid_command' USING ERRCODE='22023'; END IF;
 SELECT * INTO v FROM public.moderation_cases WHERE case_id=p_case FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE='P0002'; END IF;
 IF p_expected_updated_at IS NULL OR v.updated_at IS DISTINCT FROM p_expected_updated_at OR v.status='resolved' THEN RAISE EXCEPTION 'workflow_conflict' USING ERRCODE='PT409'; END IF;
 IF p_command='claim' THEN
   IF v.assignee_id IS NOT NULL THEN RAISE EXCEPTION 'workflow_conflict' USING ERRCODE='PT409'; END IF;
   PERFORM public.admin_assign_case(p_case,auth.uid(),'Claimed from the operator queue');
 ELSE
   IF nullif(btrim(p_note),'') IS NULL OR p_value IS NULL THEN RAISE EXCEPTION 'invalid_command' USING ERRCODE='22023'; END IF;
   IF p_command='status' THEN
     IF p_value NOT IN ('in_review','awaiting_second_review','escalated') THEN RAISE EXCEPTION 'invalid_command' USING ERRCODE='22023'; END IF;
     PERFORM public.admin_set_case_status(p_case,p_value,p_note);
   ELSE
     IF p_value NOT IN ('no_action','content_removed','user_warned','user_suspended','user_banned','user_shadow_restricted') THEN RAISE EXCEPTION 'invalid_command' USING ERRCODE='22023'; END IF;
     PERFORM public.admin_decide_case(p_case,p_value,p_policy,p_note);
   END IF;
 END IF;
 PERFORM private.record_admin_operation(auth.uid(),p_operation,'case.command',req,p_case);
END $$;

CREATE OR REPLACE FUNCTION public.admin_appeal_command(p_operation UUID,p_appeal UUID,p_outcome TEXT,p_note TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v public.moderation_appeals; req JSONB:=jsonb_build_object('appeal',p_appeal,'outcome',p_outcome,'note',p_note);
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','moderator']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 IF private.admin_operation_existing(auth.uid(),p_operation,'appeal.command',req) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('appeal_command',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF p_outcome IS NULL OR p_outcome NOT IN ('upheld','overturned') OR nullif(btrim(p_note),'') IS NULL OR length(p_note)>1000 THEN RAISE EXCEPTION 'invalid_command' USING ERRCODE='22023'; END IF;
 SELECT * INTO v FROM public.moderation_appeals WHERE appeal_id=p_appeal FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'appeal_not_found' USING ERRCODE='P0002'; END IF;
 IF v.status<>'open' THEN RAISE EXCEPTION 'workflow_conflict' USING ERRCODE='PT409'; END IF;
 -- Lock the decision being appealed before the canonical independence check.
 PERFORM 1 FROM public.moderation_cases WHERE case_id=v.case_id FOR UPDATE;
 PERFORM 1 FROM public.verification_requests WHERE request_id=v.verification_request_id FOR UPDATE;
 PERFORM public.admin_decide_appeal(p_appeal,p_outcome,p_note);
 PERFORM private.record_admin_operation(auth.uid(),p_operation,'appeal.command',req,p_appeal);
END $$;

CREATE OR REPLACE FUNCTION public.admin_safety_command(p_operation UUID,p_kind TEXT,p_target UUID,p_note TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE active BOOLEAN; req JSONB:=jsonb_build_object('kind',p_kind,'target',p_target,'note',p_note);
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','moderator']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 IF private.admin_operation_existing(auth.uid(),p_operation,'safety.command',req) IS NOT NULL THEN RETURN; END IF;
 IF NOT public.claim_rate_limit('safety_command',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 IF nullif(btrim(p_note),'') IS NULL OR length(p_note)>500 THEN RAISE EXCEPTION 'invalid_command' USING ERRCODE='22023'; END IF;
 CASE p_kind
 WHEN 'post' THEN SELECT crisis_level IS NOT NULL AND deleted_at IS NULL INTO active FROM public.posts WHERE post_id=p_target FOR UPDATE;
 WHEN 'whisper' THEN SELECT crisis_level IS NOT NULL AND deleted_at IS NULL INTO active FROM public.whispers WHERE whisper_id=p_target FOR UPDATE;
 WHEN 'tribe_message' THEN SELECT crisis_level IS NOT NULL AND deleted_at IS NULL INTO active FROM public.tribe_messages WHERE message_id=p_target FOR UPDATE;
 WHEN 'chat_message' THEN SELECT crisis_level IS NOT NULL INTO active FROM public.chat_messages WHERE message_id=p_target FOR UPDATE;
 WHEN 'report' THEN SELECT NOT is_resolved AND reason='self_harm' INTO active FROM public.reports WHERE report_id=p_target FOR UPDATE;
 ELSE RAISE EXCEPTION 'invalid_command' USING ERRCODE='22023';
 END CASE;
 IF active IS DISTINCT FROM true THEN RAISE EXCEPTION 'workflow_conflict' USING ERRCODE='PT409'; END IF;
 IF p_kind='report' THEN PERFORM public.admin_resolve_report(p_target,'safety_handled',p_note);
 ELSE PERFORM public.admin_clear_crisis_flag(p_kind,p_target,p_note); END IF;
 PERFORM private.record_admin_operation(auth.uid(),p_operation,'safety.command',req,p_target);
END $$;
REVOKE ALL ON FUNCTION public.admin_case_command(UUID,UUID,TIMESTAMPTZ,TEXT,TEXT,TEXT,TEXT),public.admin_appeal_command(UUID,UUID,TEXT,TEXT),public.admin_safety_command(UUID,TEXT,UUID,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_case_command(UUID,UUID,TIMESTAMPTZ,TEXT,TEXT,TEXT,TEXT),public.admin_appeal_command(UUID,UUID,TEXT,TEXT),public.admin_safety_command(UUID,TEXT,UUID,TEXT) TO authenticated;
SELECT public.record_migration('20261029090006','daily_workflow_closeout');
CREATE OR REPLACE FUNCTION public.admin_support_bindings(p_kind TEXT,p_query TEXT)
RETURNS TABLE(id UUID,member_id UUID,label TEXT,context TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE q TEXT:=regexp_replace(btrim(p_query),'^@',''); exact_id UUID;
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 IF p_kind IS NULL OR p_kind NOT IN ('member','appeal','verification') OR q IS NULL OR length(q) NOT BETWEEN 4 AND 50 OR q LIKE '@%' THEN RAISE EXCEPTION 'invalid_query' USING ERRCODE='22023'; END IF;
 IF NOT public.claim_rate_limit('support_binding_search',60,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 BEGIN exact_id:=q::uuid; EXCEPTION WHEN invalid_text_representation THEN exact_id:=NULL; END;
 -- Audited deliberate lookup without persisting the search text/identity.
 PERFORM private.record_operational_audit(auth.uid(),'support_binding_search',NULL,NULL,p_kind,'Scoped metadata lookup',jsonb_build_object('exact_id',exact_id IS NOT NULL));
 IF p_kind='member' THEN
 RETURN QUERY SELECT u.user_id,u.user_id,(u.display_name||' · @'||u.anonymous_pseudonym)::text,'Member'::text
 FROM public.users u WHERE (exact_id IS NOT NULL AND u.user_id=exact_id) OR (exact_id IS NULL AND starts_with(lower(u.anonymous_pseudonym),lower(ltrim(q,'@'))))
 ORDER BY u.anonymous_pseudonym,u.user_id LIMIT 25;
 ELSIF p_kind='appeal' THEN
 RETURN QUERY SELECT a.appeal_id,a.appellant_id,(u.display_name||' · @'||u.anonymous_pseudonym)::text,(a.status||' · '||to_char(a.created_at AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI')||' UTC')::text
 FROM public.moderation_appeals a JOIN public.users u ON u.user_id=a.appellant_id
 WHERE (exact_id IS NOT NULL AND a.appeal_id=exact_id) OR (exact_id IS NULL AND starts_with(lower(u.anonymous_pseudonym),lower(ltrim(q,'@'))))
 ORDER BY a.created_at DESC,a.appeal_id LIMIT 25;
 ELSE
 RETURN QUERY SELECT r.request_id,r.user_id,(u.display_name||' · @'||u.anonymous_pseudonym)::text,(r.status||' · '||to_char(r.created_at AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI')||' UTC')::text
 FROM public.verification_requests r JOIN public.users u ON u.user_id=r.user_id
 WHERE (exact_id IS NOT NULL AND r.request_id=exact_id) OR (exact_id IS NULL AND starts_with(lower(u.anonymous_pseudonym),lower(ltrim(q,'@'))))
 ORDER BY r.created_at DESC,r.request_id LIMIT 25;
 END IF;
END $$;
CREATE OR REPLACE FUNCTION public.admin_create_support_case_bound(p_operation UUID,p_source_kind TEXT,p_source_id UUID,p_member UUID,p_category TEXT,p_priority TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE member UUID;
BEGIN
 IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM private.require_aal2();
 IF p_source_id IS NOT NULL THEN
   IF p_source_kind='appeal' THEN SELECT appellant_id INTO member FROM public.moderation_appeals WHERE appeal_id=p_source_id FOR SHARE;
   ELSIF p_source_kind='verification' THEN SELECT user_id INTO member FROM public.verification_requests WHERE request_id=p_source_id FOR SHARE;
   ELSE RAISE EXCEPTION 'unsupported_source_binding' USING ERRCODE='22023'; END IF;
   IF member IS NULL THEN RAISE EXCEPTION 'source_not_found' USING ERRCODE='P0002'; END IF;
   IF p_member IS NOT NULL AND member IS DISTINCT FROM p_member THEN RAISE EXCEPTION 'source_member_mismatch' USING ERRCODE='22023'; END IF;
 ELSE member:=p_member; END IF;
 RETURN public.admin_create_support_case(p_operation,p_source_kind,p_source_id,member,p_category,p_priority);
END $$;
REVOKE ALL ON FUNCTION public.admin_support_bindings(TEXT,TEXT),public.admin_create_support_case_bound(UUID,TEXT,UUID,UUID,TEXT,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_support_bindings(TEXT,TEXT),public.admin_create_support_case_bound(UUID,TEXT,UUID,UUID,TEXT,TEXT) TO authenticated;
NOTIFY pgrst,'reload schema';
