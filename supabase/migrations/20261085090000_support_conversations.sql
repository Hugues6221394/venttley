-- Two-way support. A support case can now carry a conversation between the
-- member and the Venttly team. Members start one from Settings or by replying
-- to a staff message; staff answer from the console. A member reply puts the
-- case back in front of staff and alerts whoever owns it.
--
-- Staff are shown to members as "Venttly team", never by name or handle.
-- Messages live in private and are reachable only through these functions.
BEGIN;

-- ---------------------------------------------------------------------------
-- Cases gain a subject and conversation bookkeeping.
-- 'member'        : started by the member from the app.
-- 'staff_message' : the member replied to a staff message; source_id is the
--                   member_communications row, so one message has one thread.
-- ---------------------------------------------------------------------------
ALTER TABLE private.support_cases
  ADD COLUMN subject TEXT CHECK (subject IS NULL OR length(subject) BETWEEN 1 AND 120),
  ADD COLUMN last_message_at TIMESTAMPTZ,
  ADD COLUMN last_message_by TEXT CHECK (last_message_by IS NULL OR last_message_by IN ('member','staff')),
  ADD COLUMN member_read_at TIMESTAMPTZ;
ALTER TABLE private.support_cases DROP CONSTRAINT support_cases_source_kind_check;
ALTER TABLE private.support_cases ADD CONSTRAINT support_cases_source_kind_check CHECK (source_kind = ANY (ARRAY[
  'appeal','verification','privacy','account','recovery','safety','other','member','staff_message']));
CREATE INDEX support_cases_member_thread_idx ON private.support_cases (member_id, last_message_at DESC)
  WHERE member_id IS NOT NULL AND last_message_at IS NOT NULL;

CREATE TABLE private.support_messages (
  message_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  support_case_id UUID NOT NULL REFERENCES private.support_cases(support_case_id) ON DELETE CASCADE,
  author_kind TEXT NOT NULL CHECK (author_kind IN ('member','staff')),
  author_id UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
  client_operation UUID,
  notification_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (author_id, client_operation)
);
CREATE INDEX support_messages_thread_idx ON private.support_messages (support_case_id, created_at, message_id);
ALTER TABLE private.support_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.support_messages FROM PUBLIC, anon, authenticated;

-- What was said cannot be edited. The only changes allowed are the ones
-- account deletion makes: the author link is cleared and a member's own words
-- are redacted.
CREATE FUNCTION private.support_messages_immutable() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.message_id = OLD.message_id AND NEW.support_case_id = OLD.support_case_id
     AND NEW.author_kind = OLD.author_kind AND NEW.created_at = OLD.created_at
     AND NEW.client_operation IS NOT DISTINCT FROM OLD.client_operation
     AND NEW.notification_id IS NOT DISTINCT FROM OLD.notification_id
     AND (NEW.author_id IS NOT DISTINCT FROM OLD.author_id OR NEW.author_id IS NULL)
     AND (NEW.body = OLD.body OR (OLD.author_kind = 'member' AND NEW.body = '[removed with the account]')) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'immutable_operational_record';
END $$;
CREATE TRIGGER support_messages_immutable BEFORE UPDATE ON private.support_messages
  FOR EACH ROW EXECUTE FUNCTION private.support_messages_immutable();

-- Account deletion sets member_id to NULL; the member's words go with it.
CREATE FUNCTION private.redact_support_messages() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE private.support_messages SET body = '[removed with the account]'
   WHERE support_case_id = NEW.support_case_id AND author_kind = 'member';
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.redact_support_messages() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER support_cases_member_removed AFTER UPDATE OF member_id ON private.support_cases
  FOR EACH ROW WHEN (OLD.member_id IS NOT NULL AND NEW.member_id IS NULL)
  EXECUTE FUNCTION private.redact_support_messages();

ALTER TABLE private.support_case_events DROP CONSTRAINT support_case_events_event_kind_check;
ALTER TABLE private.support_case_events ADD CONSTRAINT support_case_events_event_kind_check CHECK (event_kind = ANY (ARRAY[
  'opened','assigned','status_changed','priority_changed','resolved','reopened','member_replied','staff_replied']));

-- ---------------------------------------------------------------------------
-- Helpers.
-- ---------------------------------------------------------------------------
-- Any member who still has an account may reach support, including suspended
-- and restricted ones: they are the people most likely to need it.
CREATE FUNCTION private.require_support_member(p_user UUID) RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_user IS NULL OR NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_user AND deactivated_at IS NULL) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;
END $$;
REVOKE ALL ON FUNCTION private.require_support_member(UUID) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION private.require_support_body(p_body TEXT) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF length(btrim(COALESCE(p_body, ''))) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'invalid_input: message must be 1 to 2000 characters';
  END IF;
  RETURN btrim(p_body);
END $$;

-- Members see four states, not the staff workflow.
CREATE FUNCTION private.member_support_status(p_status TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_status WHEN 'waiting_member' THEN 'replied' WHEN 'resolved' THEN 'resolved'
    WHEN 'closed' THEN 'closed' ELSE 'open' END;
$$;

-- A resolved conversation can be picked up again for 30 days; after that, or
-- once closed, the member starts a new one.
CREATE FUNCTION private.support_member_can_reply(c private.support_cases) RETURNS BOOLEAN
LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT c.status <> 'closed' AND (c.status <> 'resolved' OR c.resolved_at > now() - interval '30 days');
$$;

-- ---------------------------------------------------------------------------
-- Member side.
-- ---------------------------------------------------------------------------
-- The member's conversations, plus staff messages they have not replied to
-- yet, newest first.
CREATE FUNCTION public.member_support_conversations()
RETURNS TABLE(conversation_id UUID, communication_id UUID, subject TEXT, status TEXT, last_message_at TIMESTAMPTZ,
              last_message_by TEXT, unread BOOLEAN, preview TEXT, can_reply BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me UUID := auth.uid();
BEGIN
  PERFORM private.require_support_member(me);
  IF NOT public.claim_rate_limit('member_support_read', 60, 120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  RETURN QUERY
  SELECT * FROM (
    SELECT c.support_case_id, CASE WHEN c.source_kind = 'staff_message' THEN c.source_id END,
      COALESCE(c.subject, 'Support request'), private.member_support_status(c.status), c.last_message_at, c.last_message_by,
      c.last_message_by = 'staff' AND (c.member_read_at IS NULL OR c.member_read_at < c.last_message_at),
      (SELECT left(m.body, 140) FROM private.support_messages m WHERE m.support_case_id = c.support_case_id
        ORDER BY m.created_at DESC, m.message_id DESC LIMIT 1),
      private.support_member_can_reply(c)
    FROM private.support_cases c
    WHERE c.member_id = me AND c.last_message_at IS NOT NULL
    UNION ALL
    SELECT NULL::UUID, mc.communication_id, mc.subject, 'replied', mc.created_at, 'staff',
      EXISTS (SELECT 1 FROM public.notifications n WHERE n.notification_id = mc.notification_id AND NOT n.is_read),
      left(mc.body, 140), true
    FROM private.member_communications mc
    WHERE mc.member_id = me AND mc.channel = 'message' AND mc.rescinded_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM private.support_cases c WHERE c.source_kind = 'staff_message' AND c.source_id = mc.communication_id)
  ) t ORDER BY 5 DESC LIMIT 50;
END $$;

-- One conversation. Opening it marks staff replies as read.
CREATE FUNCTION public.member_support_thread(p_conversation UUID DEFAULT NULL, p_communication UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me UUID := auth.uid(); c private.support_cases; mc private.member_communications;
BEGIN
  PERFORM private.require_support_member(me);
  IF (p_conversation IS NULL) = (p_communication IS NULL) THEN RAISE EXCEPTION 'invalid_input: one of conversation or communication'; END IF;
  IF NOT public.claim_rate_limit('member_support_read', 60, 120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_conversation IS NOT NULL THEN
    SELECT * INTO c FROM private.support_cases WHERE support_case_id = p_conversation AND member_id = me;
  ELSE
    SELECT * INTO mc FROM private.member_communications
     WHERE communication_id = p_communication AND member_id = me AND channel = 'message' AND rescinded_at IS NULL;
    IF mc.communication_id IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0002'; END IF;
    SELECT * INTO c FROM private.support_cases WHERE source_kind = 'staff_message' AND source_id = p_communication AND member_id = me;
    IF c.support_case_id IS NULL THEN
      RETURN jsonb_build_object('conversation_id', NULL, 'communication_id', mc.communication_id, 'subject', mc.subject,
        'status', 'replied', 'can_reply', true,
        'messages', jsonb_build_array(jsonb_build_object('id', mc.communication_id, 'from', 'venttly', 'body', mc.body, 'created_at', mc.created_at)));
    END IF;
  END IF;
  IF c.support_case_id IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0002'; END IF;
  UPDATE private.support_cases SET member_read_at = clock_timestamp() WHERE support_case_id = c.support_case_id;
  RETURN jsonb_build_object('conversation_id', c.support_case_id,
    'communication_id', CASE WHEN c.source_kind = 'staff_message' THEN c.source_id END,
    'subject', COALESCE(c.subject, 'Support request'), 'status', private.member_support_status(c.status),
    'can_reply', private.support_member_can_reply(c),
    'messages', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', m.message_id,
        'from', CASE m.author_kind WHEN 'member' THEN 'me' ELSE 'venttly' END, 'body', m.body, 'created_at', m.created_at)
        ORDER BY m.created_at, m.message_id)
      FROM private.support_messages m WHERE m.support_case_id = c.support_case_id), '[]'::JSONB));
END $$;

CREATE FUNCTION public.member_start_support(p_operation UUID, p_category TEXT, p_subject TEXT, p_body TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE me UUID := auth.uid(); v_case UUID; v_body TEXT; v_priority TEXT;
BEGIN
  PERFORM private.require_support_member(me);
  IF p_operation IS NULL THEN RAISE EXCEPTION 'invalid_input: operation is required'; END IF;
  SELECT m.support_case_id INTO v_case FROM private.support_messages m WHERE m.author_id = me AND m.client_operation = p_operation;
  IF v_case IS NOT NULL THEN RETURN v_case; END IF;
  IF p_category IS NULL OR p_category NOT IN ('access','technical','privacy_request','safety_followup','appeal_help','verification_help','other') THEN
    RAISE EXCEPTION 'invalid_input: unknown category';
  END IF;
  IF length(btrim(COALESCE(p_subject, ''))) NOT BETWEEN 3 AND 80 THEN
    RAISE EXCEPTION 'invalid_input: subject must be 3 to 80 characters';
  END IF;
  v_body := private.require_support_body(p_body);
  IF (SELECT count(*) FROM private.support_cases WHERE member_id = me AND source_kind = 'member'
       AND status NOT IN ('resolved','closed')) >= 3 THEN
    RAISE EXCEPTION 'too_many_open: finish an open conversation first';
  END IF;
  IF NOT public.claim_rate_limit('member_support_start', 86400, 5) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  v_priority := CASE WHEN p_category = 'safety_followup' THEN 'high' ELSE 'normal' END;
  INSERT INTO private.support_cases (source_kind, member_id, category, priority, status, sla_due_at, created_by,
                                     subject, last_message_at, last_message_by, member_read_at)
  VALUES ('member', me, p_category, v_priority, 'open',
          now() + CASE v_priority WHEN 'high' THEN interval '4 hours' ELSE interval '24 hours' END, me,
          btrim(p_subject), clock_timestamp(), 'member', clock_timestamp())
  RETURNING support_case_id INTO v_case;
  INSERT INTO private.support_case_events (support_case_id, event_kind, actor_id, detail)
  VALUES (v_case, 'opened', me, jsonb_build_object('category', p_category, 'priority', v_priority, 'by', 'member'));
  INSERT INTO private.support_messages (support_case_id, author_kind, author_id, body, client_operation, created_at)
  VALUES (v_case, 'member', me, v_body, p_operation, clock_timestamp());
  RETURN v_case;
END $$;

-- Reply in a conversation, or to a staff message (which starts its thread,
-- owned by the staff member who sent it while they can still take support).
CREATE FUNCTION public.member_reply_support(p_operation UUID, p_body TEXT,
  p_conversation UUID DEFAULT NULL, p_communication UUID DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  me UUID := auth.uid(); c private.support_cases; mc private.member_communications;
  v_case UUID; v_body TEXT; v_status TEXT; v_message UUID; v_owner UUID;
BEGIN
  PERFORM private.require_support_member(me);
  IF p_operation IS NULL THEN RAISE EXCEPTION 'invalid_input: operation is required'; END IF;
  IF (p_conversation IS NULL) = (p_communication IS NULL) THEN RAISE EXCEPTION 'invalid_input: one of conversation or communication'; END IF;
  SELECT m.support_case_id INTO v_case FROM private.support_messages m WHERE m.author_id = me AND m.client_operation = p_operation;
  IF v_case IS NOT NULL THEN RETURN v_case; END IF;
  v_body := private.require_support_body(p_body);
  IF NOT public.claim_rate_limit('member_support_reply', 3600, 30) THEN RAISE EXCEPTION 'rate_limited'; END IF;

  IF p_communication IS NOT NULL THEN
    SELECT * INTO mc FROM private.member_communications
     WHERE communication_id = p_communication AND member_id = me AND channel = 'message' AND rescinded_at IS NULL;
    IF mc.communication_id IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0002'; END IF;
    SELECT support_case_id INTO v_case FROM private.support_cases WHERE source_kind = 'staff_message' AND source_id = p_communication;
    IF v_case IS NULL THEN
      v_owner := CASE WHEN public.is_staff(mc.actor_id, ARRAY['super_admin','admin','support']) THEN mc.actor_id END;
      INSERT INTO private.support_cases (source_kind, source_id, member_id, category, priority, status, assigned_to,
                                         sla_due_at, first_response_at, created_by, subject)
      VALUES ('staff_message', mc.communication_id, me, 'other', 'normal',
              CASE WHEN v_owner IS NULL THEN 'open' ELSE 'assigned' END, v_owner,
              now() + interval '24 hours', mc.created_at, me, mc.subject)
      ON CONFLICT (source_kind, source_id) WHERE source_id IS NOT NULL DO NOTHING
      RETURNING support_case_id INTO v_case;
      IF v_case IS NULL THEN
        SELECT support_case_id INTO v_case FROM private.support_cases WHERE source_kind = 'staff_message' AND source_id = p_communication;
      ELSE
        INSERT INTO private.support_case_events (support_case_id, event_kind, actor_id, detail)
        VALUES (v_case, 'opened', me, jsonb_build_object('category', 'other', 'priority', 'normal', 'by', 'member_reply'));
        INSERT INTO private.support_messages (support_case_id, author_kind, author_id, body, created_at)
        VALUES (v_case, 'staff', mc.actor_id, mc.body, mc.created_at);
      END IF;
    END IF;
  ELSE
    v_case := p_conversation;
  END IF;

  SELECT * INTO c FROM private.support_cases WHERE support_case_id = v_case AND member_id = me FOR UPDATE;
  IF c.support_case_id IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0002'; END IF;
  IF NOT private.support_member_can_reply(c) THEN RAISE EXCEPTION 'conversation_closed: start a new conversation'; END IF;

  -- Staff owe the next answer: the case leaves "waiting on member" and gets a
  -- fresh deadline; an internal hold stays where it is.
  v_status := CASE WHEN c.status = 'waiting_internal' THEN c.status
                   WHEN c.assigned_to IS NOT NULL THEN 'assigned' ELSE 'open' END;
  UPDATE private.support_cases SET
    status = v_status, resolved_at = NULL,
    sla_due_at = CASE WHEN c.status IN ('waiting_member','resolved') THEN now() + interval '24 hours' ELSE c.sla_due_at END,
    last_message_at = clock_timestamp(), last_message_by = 'member', member_read_at = clock_timestamp(), updated_at = now()
  WHERE support_case_id = v_case;
  INSERT INTO private.support_messages (support_case_id, author_kind, author_id, body, client_operation, created_at)
  VALUES (v_case, 'member', me, v_body, p_operation, clock_timestamp()) RETURNING message_id INTO v_message;
  INSERT INTO private.support_case_events (support_case_id, event_kind, actor_id, detail)
  VALUES (v_case, CASE WHEN c.status = 'resolved' THEN 'reopened' ELSE 'member_replied' END, me,
          jsonb_build_object('from', c.status, 'to', v_status));

  IF c.assigned_to IS NOT NULL AND (SELECT enabled FROM private.staff_inbox_control WHERE singleton) THEN
    INSERT INTO private.staff_event_outbox (event_key, kind, source_id, intended_recipient, severity)
    VALUES ('support-reply:' || v_message, 'support_member_replied', v_case, c.assigned_to,
            CASE WHEN c.priority = 'critical' THEN 'critical' ELSE 'info' END)
    ON CONFLICT (event_key) DO NOTHING;
  END IF;
  RETURN v_case;
END $$;

-- ---------------------------------------------------------------------------
-- Staff side.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.admin_support_conversation(p_case UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE c private.support_cases;
BEGIN
  IF NOT public.is_staff(auth.uid(), ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501'; END IF;
  IF NOT public.claim_rate_limit('support_conversation_read', 60, 120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO c FROM private.support_cases WHERE support_case_id = p_case;
  IF c.support_case_id IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0002'; END IF;
  RETURN jsonb_build_object(
    'support_case_id', c.support_case_id, 'subject', c.subject, 'source_kind', c.source_kind, 'category', c.category,
    'priority', c.priority, 'status', c.status, 'member_id', c.member_id,
    'member_pseudonym', (SELECT anonymous_pseudonym FROM public.users WHERE user_id = c.member_id),
    'assignee_id', c.assigned_to, 'assignee_name', (SELECT display_name FROM public.users WHERE user_id = c.assigned_to),
    'sla_due_at', c.sla_due_at, 'created_at', c.created_at, 'updated_at', c.updated_at,
    'member_read_at', c.member_read_at, 'can_reply', c.member_id IS NOT NULL AND c.status <> 'closed',
    'messages', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', m.message_id, 'author_kind', m.author_kind,
        'author_name', CASE WHEN m.author_kind = 'staff' THEN COALESCE(u.display_name, 'Former staff') ELSE COALESCE(u.anonymous_pseudonym, 'Member') END,
        'body', m.body, 'created_at', m.created_at) ORDER BY m.created_at, m.message_id)
      FROM private.support_messages m LEFT JOIN public.users u ON u.user_id = m.author_id
      WHERE m.support_case_id = c.support_case_id), '[]'::JSONB));
END $$;

-- Staff reply. Replying takes ownership of an unowned case, so the member's
-- answer reaches someone. Optionally resolves in the same step.
CREATE FUNCTION public.admin_reply_support(p_operation UUID, p_case UUID, p_body TEXT, p_resolve BOOLEAN DEFAULT false)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  actor UUID := auth.uid(); c private.support_cases; v_body TEXT; v_status TEXT; v_message UUID; v_notification UUID;
  request JSONB := jsonb_build_object('case', p_case, 'body', p_body, 'resolve', p_resolve);
  v_existing UUID;
BEGIN
  IF NOT public.is_staff(actor, ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501'; END IF;
  PERFORM private.require_aal2();
  IF p_operation IS NULL OR p_resolve IS NULL THEN RAISE EXCEPTION 'invalid_input: operation is required'; END IF;
  v_existing := private.admin_operation_existing(actor, p_operation, 'support.reply', request);
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  v_body := private.require_support_body(p_body);
  IF NOT public.claim_rate_limit('support_reply', 3600, 120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO c FROM private.support_cases WHERE support_case_id = p_case FOR UPDATE;
  IF c.support_case_id IS NULL THEN RAISE EXCEPTION 'support_case_not_found' USING ERRCODE = 'P0002'; END IF;
  IF c.status = 'closed' THEN RAISE EXCEPTION 'closed_support_case' USING ERRCODE = '22023'; END IF;
  IF c.member_id IS NULL THEN RAISE EXCEPTION 'invalid_input: this case has no member to reply to'; END IF;

  v_status := CASE WHEN p_resolve THEN 'resolved' ELSE 'waiting_member' END;
  INSERT INTO public.notifications (user_id, kind, payload)
  VALUES (c.member_id, 'system', jsonb_build_object(
    'title', 'Reply from the Venttly team', 'body', left(v_body, 280),
    'source', 'venttly_team', 'support_case_id', c.support_case_id))
  RETURNING notification_id INTO v_notification;
  INSERT INTO private.support_messages (support_case_id, author_kind, author_id, body, notification_id, created_at)
  VALUES (c.support_case_id, 'staff', actor, v_body, v_notification, clock_timestamp()) RETURNING message_id INTO v_message;
  UPDATE private.support_cases SET
    status = v_status, assigned_to = COALESCE(c.assigned_to, actor),
    resolved_at = CASE WHEN p_resolve THEN now() END,
    first_response_at = COALESCE(c.first_response_at, now()),
    sla_due_at = CASE WHEN p_resolve THEN c.sla_due_at ELSE now() + interval '7 days' END,
    last_message_at = clock_timestamp(), last_message_by = 'staff', updated_at = now()
  WHERE support_case_id = c.support_case_id;
  INSERT INTO private.support_case_events (support_case_id, event_kind, actor_id, detail)
  VALUES (c.support_case_id, CASE WHEN p_resolve THEN 'resolved' ELSE 'staff_replied' END, actor,
          jsonb_build_object('from', c.status, 'to', v_status));
  PERFORM private.record_admin_operation(actor, p_operation, 'support.reply', request, v_message);
  PERFORM private.record_operational_audit(actor, 'support.reply', 'support_case', c.support_case_id, c.category,
    'Replied to the member in a support conversation.', jsonb_build_object('resolved', p_resolve, 'message_id', v_message));
  RETURN v_message;
END $$;

-- The queue now says who spoke last and what the case is about.
DROP FUNCTION public.admin_support_case_queue(INTEGER);
CREATE FUNCTION public.admin_support_case_queue(p_limit INTEGER DEFAULT 100)
RETURNS TABLE(support_case_id UUID, source_kind TEXT, source_id UUID, member_id UUID, category TEXT, priority TEXT, status TEXT,
              assignee_id UUID, assignee_name TEXT, sla_due_at TIMESTAMPTZ, first_response_at TIMESTAMPTZ, resolved_at TIMESTAMPTZ,
              created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, subject TEXT, last_message_at TIMESTAMPTZ, last_message_by TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin','support']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT c.support_case_id,c.source_kind,c.source_id,c.member_id,c.category,c.priority,c.status,c.assigned_to,
    u.display_name,c.sla_due_at,c.first_response_at,c.resolved_at,c.created_at,c.updated_at,c.subject,c.last_message_at,c.last_message_by
    FROM private.support_cases c LEFT JOIN public.users u ON u.user_id=c.assigned_to
   ORDER BY (c.status NOT IN ('resolved','closed')) DESC,c.sla_due_at ASC,c.created_at DESC
   LIMIT greatest(1,least(p_limit,200));
END;
$$;

REVOKE ALL ON FUNCTION public.member_support_conversations(), public.member_support_thread(UUID,UUID),
  public.member_start_support(UUID,TEXT,TEXT,TEXT), public.member_reply_support(UUID,TEXT,UUID,UUID),
  public.admin_support_conversation(UUID), public.admin_reply_support(UUID,UUID,TEXT,BOOLEAN),
  public.admin_support_case_queue(INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.member_support_conversations(), public.member_support_thread(UUID,UUID),
  public.member_start_support(UUID,TEXT,TEXT,TEXT), public.member_reply_support(UUID,TEXT,UUID,UUID),
  public.admin_support_conversation(UUID), public.admin_reply_support(UUID,UUID,TEXT,BOOLEAN),
  public.admin_support_case_queue(INTEGER) TO authenticated;
REVOKE ALL ON FUNCTION private.require_support_body(TEXT), private.member_support_status(TEXT),
  private.support_member_can_reply(private.support_cases) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Staff inbox: a "member replied" notice for the case owner. The functions
-- below are the live definitions with the new kind added.
-- ---------------------------------------------------------------------------
ALTER TABLE private.staff_event_outbox DROP CONSTRAINT staff_event_outbox_kind_check;
ALTER TABLE private.staff_event_outbox ADD CONSTRAINT staff_event_outbox_kind_check CHECK(kind IN (
 'support_assigned','support_sla_breached','support_member_replied','legal_review_requested','moderation_assigned','moderation_review_requested',
 'job_push_attention','job_email_attention','job_media_attention','impact_report_ready','incident_changed','incident_overdue',
 'access_review_assigned','access_review_overdue','promotion_review_requested','promotion_ready','broadcast_review_requested','broadcast_ready'));

-- A thread opened by a member's reply already raises the "member replied"
-- notice; it does not also announce the assignment.
CREATE OR REPLACE FUNCTION private.enqueue_staff_source_event()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  IF NOT (SELECT enabled FROM private.staff_inbox_control WHERE singleton) THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME='support_cases' THEN
    IF NEW.assigned_to IS NOT NULL AND (TG_OP='INSERT' OR NEW.assigned_to IS DISTINCT FROM OLD.assigned_to)
       AND NOT (TG_OP='INSERT' AND NEW.source_kind='staff_message') THEN
      INSERT INTO private.staff_event_outbox(event_key,kind,source_id,intended_recipient,severity)
      VALUES('support-assigned:'||NEW.support_case_id||':'||gen_random_uuid(), 'support_assigned',
        NEW.support_case_id,NEW.assigned_to,CASE WHEN NEW.priority='critical' THEN 'critical' ELSE 'info' END);
    END IF;
  ELSIF TG_TABLE_NAME='legal_requests' THEN
    IF NEW.status='awaiting_approval' AND (TG_OP='INSERT' OR NEW.status IS DISTINCT FROM OLD.status) THEN
      INSERT INTO private.staff_event_outbox(event_key,kind,source_id,severity)
      VALUES('legal-review:'||NEW.legal_request_id||':'||gen_random_uuid(),'legal_review_requested',NEW.legal_request_id,'warning');
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION private.can_read_staff_event(p_actor uuid, p_kind text, p_source uuid)
 RETURNS boolean LANGUAGE sql STABLE SET search_path TO '' AS $function$
 SELECT CASE
 WHEN p_kind IN ('access_review_assigned','access_review_overdue','promotion_review_requested','promotion_ready','broadcast_review_requested','broadcast_ready') THEN private.can_read_governance_notice(p_actor,p_kind,p_source)
 WHEN p_kind IN ('incident_changed','incident_overdue') THEN private.can_read_incident_notice(p_actor,p_kind,p_source)
 WHEN p_kind IN ('support_assigned','support_sla_breached','support_member_replied') THEN
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
$function$;

CREATE OR REPLACE FUNCTION public.admin_staff_inbox_page(p_filter text DEFAULT 'all'::text, p_category text DEFAULT 'all'::text, p_severity text DEFAULT 'all'::text, p_limit integer DEFAULT 30, p_before_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(event_id uuid, kind text, severity text, source_id uuid, destination text, delivered_at timestamp with time zone, read_at timestamp with time zone)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
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
   WHEN o.kind='support_member_replied' THEN '/support/cases/'||o.source_id
   WHEN o.kind LIKE 'job_%' THEN '/jobs#'||CASE o.kind WHEN 'job_push_attention' THEN 'push-failures' WHEN 'job_email_attention' THEN 'email-failures' ELSE 'media-stalled' END
   ELSE '/support/cases' END,d.delivered_at,d.read_at
 FROM private.staff_inbox_deliveries d JOIN private.staff_event_outbox o USING(event_id)
 WHERE d.recipient_id=actor AND private.can_read_staff_event(actor,o.kind,o.source_id)
  AND (p_filter<>'unread' OR d.read_at IS NULL) AND (p_filter<>'urgent' OR o.severity='critical')
  AND (p_filter<>'assigned' OR (o.kind IN ('access_review_assigned','access_review_overdue','promotion_ready','broadcast_ready') AND private.can_read_governance_notice(actor,o.kind,o.source_id)) OR (o.kind IN ('incident_changed','incident_overdue') AND private.can_read_incident_notice(actor,o.kind,o.source_id)) OR
   (o.kind IN ('support_assigned','support_sla_breached','support_member_replied') AND EXISTS(SELECT 1 FROM private.support_cases c WHERE c.support_case_id=o.source_id AND c.assigned_to=actor AND c.status NOT IN ('resolved','closed')))
   OR (o.kind IN ('moderation_assigned','moderation_review_requested') AND EXISTS(SELECT 1 FROM public.moderation_cases c WHERE c.case_id=o.source_id AND c.assignee_id=actor AND c.status<>'resolved')))
  AND (p_category='all' OR (p_category='governance' AND o.kind IN ('access_review_assigned','access_review_overdue','promotion_review_requested','promotion_ready','broadcast_review_requested','broadcast_ready')) OR (p_category='incidents' AND o.kind IN ('incident_changed','incident_overdue')) OR (p_category='legal' AND o.kind='legal_review_requested')
   OR (p_category='support' AND o.kind IN ('support_assigned','support_sla_breached','support_member_replied'))
   OR (p_category='moderation' AND o.kind IN ('moderation_assigned','moderation_review_requested'))
   OR (p_category='jobs' AND o.kind IN ('job_push_attention','job_email_attention','job_media_attention'))
   OR (p_category='reports' AND o.kind='impact_report_ready'))
  AND (p_severity='all' OR o.severity=p_severity)
  AND (p_before_at IS NULL OR (d.delivered_at,d.event_id)<(p_before_at,p_before_id))
 ORDER BY d.delivered_at DESC,d.event_id DESC LIMIT p_limit;
END $function$;

CREATE OR REPLACE FUNCTION private.prune_staff_inbox_deliveries(p_limit integer DEFAULT 500)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
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
   AND o.kind IN ('support_assigned','support_sla_breached','support_member_replied')
  ORDER BY d.delivered_at,d.event_id,d.recipient_id LIMIT p_limit FOR UPDATE OF d SKIP LOCKED
 ), removed_rows AS (
  DELETE FROM private.staff_inbox_deliveries d USING expired e WHERE d.event_id=e.event_id AND d.recipient_id=e.recipient_id RETURNING 1
 ) SELECT count(*)::INTEGER INTO removed FROM removed_rows;
 UPDATE private.staff_inbox_runtime SET retention_at=clock_timestamp(),pruned_deliveries=removed WHERE singleton;
 RETURN removed;
END $function$;

NOTIFY pgrst, 'reload schema';
COMMIT;

SELECT public.record_migration('20261085090000', 'support_conversations');
