-- Staff can reach one member: an in-app message from the Venttly team, a
-- standalone formal warning, or an email when the member has a real address.
--
-- private.member_communications is the staff record of what was sent. It is
-- separate from the member's notifications on purpose: a member may delete a
-- notice from their own feed, and that must not erase what staff told them.
-- Push needs nothing here. Every notifications insert already fans out, and the
-- push copy is generic, so no staff-written text reaches a lock screen.

CREATE TABLE IF NOT EXISTS private.member_communications (
  communication_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id        UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  actor_id         UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  actor_pseudonym  TEXT,
  actor_role       TEXT NOT NULL,
  channel          TEXT NOT NULL CHECK (channel IN ('message','warning','email')),
  subject          TEXT NOT NULL CHECK (length(subject) BETWEEN 1 AND 120),
  body             TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
  policy_code      TEXT CHECK (policy_code IS NULL OR length(policy_code) <= 40),
  appealable       BOOLEAN,
  notification_id  UUID,
  email_outbox_id  UUID,
  email_hint       TEXT,
  rescinded_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS member_communications_member_idx
  ON private.member_communications (member_id, created_at DESC);
CREATE INDEX IF NOT EXISTS member_communications_notification_idx
  ON private.member_communications (notification_id) WHERE notification_id IS NOT NULL;
ALTER TABLE private.member_communications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.member_communications FROM PUBLIC, anon, authenticated;

-- What was said is immutable. The only change is a warning being rescinded on
-- appeal, once.
CREATE OR REPLACE FUNCTION private.member_communications_immutable()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF OLD.rescinded_at IS NULL AND NEW.rescinded_at IS NOT NULL
     AND (to_jsonb(NEW) - 'rescinded_at') = (to_jsonb(OLD) - 'rescinded_at') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'member communications are immutable' USING ERRCODE = '42501';
END $$;
DROP TRIGGER IF EXISTS member_communications_immutable ON private.member_communications;
CREATE TRIGGER member_communications_immutable
  BEFORE UPDATE ON private.member_communications
  FOR EACH ROW EXECUTE FUNCTION private.member_communications_immutable();

-- A deliverable address or NULL. A verified recovery email wins over the auth
-- email; the synthetic <handle>@id.venttly.app is never an address.
CREATE OR REPLACE FUNCTION private.member_email_address(p_member UUID)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(
    (SELECT u.recovery_email FROM public.users u
      WHERE u.user_id = p_member AND u.recovery_email_verified
        AND NULLIF(btrim(u.recovery_email), '') IS NOT NULL),
    (SELECT a.email FROM auth.users a
      WHERE a.id = p_member AND a.email_confirmed_at IS NOT NULL
        AND NULLIF(btrim(a.email), '') IS NOT NULL
        AND a.email NOT LIKE '%@id.venttly.app'));
$$;
REVOKE ALL ON FUNCTION private.member_email_address(UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.mask_email(p_email TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN p_email IS NULL OR position('@' IN p_email) < 2 THEN NULL
    ELSE left(p_email, 1) || '•••@' || split_part(p_email, '@', 2) END;
$$;
REVOKE ALL ON FUNCTION private.mask_email(TEXT) FROM PUBLIC, anon, authenticated;

-- Shared checks for every send. Returns the member's display label.
CREATE OR REPLACE FUNCTION private.require_contactable_member(p_actor UUID, p_member UUID)
RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_label TEXT;
BEGIN
  IF p_member IS NULL THEN RAISE EXCEPTION 'invalid_input: member is required'; END IF;
  IF p_member = p_actor THEN RAISE EXCEPTION 'invalid_input: you cannot contact yourself'; END IF;
  SELECT '@' || u.anonymous_pseudonym INTO v_label FROM public.users u WHERE u.user_id = p_member;
  IF v_label IS NULL THEN RAISE EXCEPTION 'not_found: member'; END IF;
  RETURN v_label;
END $$;
REVOKE ALL ON FUNCTION private.require_contactable_member(UUID, UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.require_contact_text(p_subject TEXT, p_body TEXT)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF length(btrim(COALESCE(p_subject, ''))) NOT BETWEEN 3 AND 80 THEN
    RAISE EXCEPTION 'invalid_input: subject must be 3 to 80 characters';
  END IF;
  IF length(btrim(COALESCE(p_body, ''))) NOT BETWEEN 10 AND 1000 THEN
    RAISE EXCEPTION 'invalid_input: message must be 10 to 1000 characters';
  END IF;
END $$;
REVOKE ALL ON FUNCTION private.require_contact_text(TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- In-app message from the Venttly team
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_message_member(
  p_operation UUID, p_member UUID, p_subject TEXT, p_body TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  actor UUID := auth.uid();
  request JSONB := jsonb_build_object('member', p_member, 'subject', p_subject, 'body', p_body);
  v_existing UUID; v_label TEXT; v_notification UUID; v_id UUID;
BEGIN
  IF NOT public.is_staff(actor, ARRAY['super_admin','admin','support']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_aal2();
  IF p_operation IS NULL THEN RAISE EXCEPTION 'invalid_input: operation is required'; END IF;
  v_existing := private.admin_operation_existing(actor, p_operation, 'member.message', request);
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  PERFORM private.require_contact_text(p_subject, p_body);
  v_label := private.require_contactable_member(actor, p_member);
  IF NOT public.claim_rate_limit('member_message', 3600, 30) THEN RAISE EXCEPTION 'rate_limited'; END IF;

  v_id := gen_random_uuid();
  INSERT INTO public.notifications (user_id, kind, payload)
  VALUES (p_member, 'system', jsonb_build_object(
    'title', btrim(p_subject), 'body', btrim(p_body),
    'source', 'venttly_team', 'communication_id', v_id))
  RETURNING notification_id INTO v_notification;

  INSERT INTO private.member_communications
    (communication_id, member_id, actor_id, actor_pseudonym, actor_role, channel, subject, body, notification_id)
  SELECT v_id, p_member, actor, u.anonymous_pseudonym, u.user_role::TEXT, 'message', btrim(p_subject), btrim(p_body), v_notification
    FROM public.users u WHERE u.user_id = actor;

  PERFORM private.record_admin_operation(actor, p_operation, 'member.message', request, v_id);
  PERFORM private.record_operational_audit(actor, 'member.message', 'user', p_member, v_label,
    'Sent an in-app message from the Venttly team.', jsonb_build_object('communication_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- Formal warning: recorded, shown in the member's Appeals & warnings history,
-- appealable through the existing account-appeal path.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_warn_member(
  p_operation UUID, p_member UUID, p_policy TEXT, p_reason TEXT, p_appealable BOOLEAN DEFAULT true
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  actor UUID := auth.uid();
  request JSONB := jsonb_build_object('member', p_member, 'policy', p_policy, 'reason', p_reason, 'appealable', p_appealable);
  v_existing UUID; v_label TEXT; v_audit UUID; v_notification UUID; v_id UUID;
  v_policy TEXT := NULLIF(btrim(COALESCE(p_policy, '')), '');
BEGIN
  IF NOT public.is_staff(actor, ARRAY['super_admin','admin']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_aal2();
  IF p_operation IS NULL THEN RAISE EXCEPTION 'invalid_input: operation is required'; END IF;
  v_existing := private.admin_operation_existing(actor, p_operation, 'member.warning', request);
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  IF p_appealable IS NULL THEN RAISE EXCEPTION 'invalid_input: appealable is required'; END IF;
  IF v_policy IS NOT NULL AND length(v_policy) > 40 THEN
    RAISE EXCEPTION 'invalid_input: policy code must be at most 40 characters';
  END IF;
  IF length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 10 AND 1000 THEN
    RAISE EXCEPTION 'invalid_input: reason must be 10 to 1000 characters';
  END IF;
  v_label := private.require_contactable_member(actor, p_member);
  IF NOT public.claim_rate_limit('member_warning', 3600, 20) THEN RAISE EXCEPTION 'rate_limited'; END IF;

  -- admin_log returns the audit id, which the account-appeal path reads as the
  -- decision reference to find who issued the warning.
  v_audit := public.admin_log('member.warning', 'user', p_member, v_label, NULL,
    jsonb_build_object('policy', v_policy, 'appealable', p_appealable), btrim(p_reason), '{}'::jsonb);

  PERFORM private.notify_enforcement(p_member, 'case_user_warned', NULL, v_policy, btrim(p_reason), p_appealable, v_audit);
  SELECT n.notification_id INTO v_notification FROM public.notifications n
   WHERE n.user_id = p_member AND n.kind = 'moderation_action' AND n.payload->>'decision_ref' = v_audit::TEXT
   ORDER BY n.created_at DESC LIMIT 1;

  v_id := gen_random_uuid();
  INSERT INTO private.member_communications
    (communication_id, member_id, actor_id, actor_pseudonym, actor_role, channel, subject, body,
     policy_code, appealable, notification_id)
  SELECT v_id, p_member, actor, u.anonymous_pseudonym, u.user_role::TEXT, 'warning', 'Formal warning', btrim(p_reason),
         v_policy, p_appealable, v_notification
    FROM public.users u WHERE u.user_id = actor;

  PERFORM private.record_admin_operation(actor, p_operation, 'member.warning', request, v_id);
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- Email, only to a deliverable address. Drained by email-dispatcher using the
-- staff_message template.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_email_member(
  p_operation UUID, p_member UUID, p_subject TEXT, p_body TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  actor UUID := auth.uid();
  request JSONB := jsonb_build_object('member', p_member, 'subject', p_subject, 'body', p_body);
  v_existing UUID; v_label TEXT; v_address TEXT; v_outbox UUID; v_id UUID;
BEGIN
  IF NOT public.is_staff(actor, ARRAY['super_admin','admin','support']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;
  PERFORM private.require_aal2();
  IF p_operation IS NULL THEN RAISE EXCEPTION 'invalid_input: operation is required'; END IF;
  v_existing := private.admin_operation_existing(actor, p_operation, 'member.email', request);
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  PERFORM private.require_contact_text(p_subject, p_body);
  v_label := private.require_contactable_member(actor, p_member);
  v_address := private.member_email_address(p_member);
  IF v_address IS NULL THEN
    RAISE EXCEPTION 'email_unavailable: this member has no verified email address';
  END IF;
  IF NOT public.claim_rate_limit('member_email', 3600, 20) THEN RAISE EXCEPTION 'rate_limited'; END IF;

  INSERT INTO public.email_outbox (user_id, template, to_address, variables)
  VALUES (p_member, 'staff_message', v_address,
          jsonb_build_object('subject', btrim(p_subject), 'body', btrim(p_body)))
  RETURNING outbox_id INTO v_outbox;

  v_id := gen_random_uuid();
  INSERT INTO private.member_communications
    (communication_id, member_id, actor_id, actor_pseudonym, actor_role, channel, subject, body,
     email_outbox_id, email_hint)
  SELECT v_id, p_member, actor, u.anonymous_pseudonym, u.user_role::TEXT, 'email', btrim(p_subject), btrim(p_body),
         v_outbox, private.mask_email(v_address)
    FROM public.users u WHERE u.user_id = actor;

  PERFORM private.record_admin_operation(actor, p_operation, 'member.email', request, v_id);
  PERFORM private.record_operational_audit(actor, 'member.email', 'user', p_member, v_label,
    'Queued an email from the Venttly team.', jsonb_build_object('communication_id', v_id));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- Reads for the member profile
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_member_contact_options(p_member UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE actor UUID := auth.uid(); v_address TEXT;
BEGIN
  IF NOT public.is_staff(actor, ARRAY['super_admin','admin','support']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE user_id = p_member) THEN
    RAISE EXCEPTION 'not_found: member';
  END IF;
  v_address := private.member_email_address(p_member);
  RETURN jsonb_build_object(
    'email_available', v_address IS NOT NULL,
    'email_hint', private.mask_email(v_address),
    'can_message', true,
    'can_warn', public.is_staff(actor, ARRAY['super_admin','admin']),
    'is_self', p_member = actor);
END $$;

CREATE OR REPLACE FUNCTION public.admin_member_communications(p_member UUID, p_limit INT DEFAULT 50)
RETURNS TABLE (
  communication_id UUID, channel TEXT, subject TEXT, body TEXT, policy_code TEXT, appealable BOOLEAN,
  actor_pseudonym TEXT, actor_role TEXT, email_hint TEXT, delivery_status TEXT,
  rescinded_at TIMESTAMPTZ, created_at TIMESTAMPTZ
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(), ARRAY['super_admin','admin','support']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.communication_id, c.channel, c.subject, c.body, c.policy_code, c.appealable,
         c.actor_pseudonym, c.actor_role, c.email_hint,
         CASE WHEN c.channel = 'email' THEN COALESCE(o.status, 'unknown')
              WHEN c.notification_id IS NULL THEN 'unknown'
              WHEN n.notification_id IS NULL THEN 'removed_by_member'
              WHEN n.is_read THEN 'read'
              ELSE 'delivered' END,
         c.rescinded_at, c.created_at
    FROM private.member_communications c
    LEFT JOIN public.email_outbox o ON o.outbox_id = c.email_outbox_id
    LEFT JOIN public.notifications n ON n.notification_id = c.notification_id
   WHERE c.member_id = p_member
   ORDER BY c.created_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
END $$;

REVOKE ALL ON FUNCTION public.admin_message_member(UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_warn_member(UUID, UUID, TEXT, TEXT, BOOLEAN) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_email_member(UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_member_contact_options(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_member_communications(UUID, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_message_member(UUID, UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_warn_member(UUID, UUID, TEXT, TEXT, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_email_member(UUID, UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_member_contact_options(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_member_communications(UUID, INT) TO authenticated;

-- ---------------------------------------------------------------------------
-- Overturning an appeal against a staff warning rescinds the warning. The
-- account-level branch otherwise lifts a suspension, which for a warning would
-- reinstate an account that may be suspended for something else entirely.
-- Unchanged from 20261025090000 apart from that branch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_decide_appeal(p_appeal uuid, p_outcome text, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_appeal moderation_appeals;
    v_case   moderation_cases;
    v_req    verification_requests;
    v_actor  UUID := auth.uid();
    v_decider UUID;
    v_reversed JSONB := '{}'::jsonb;
    v_target_label TEXT;
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    PERFORM private.require_aal2();
    IF p_outcome NOT IN ('upheld', 'overturned') THEN
        RAISE EXCEPTION 'outcome must be upheld or overturned';
    END IF;
    IF COALESCE(btrim(p_note), '') = '' THEN
        RAISE EXCEPTION 'an appeal outcome requires a note: it is what the member is told';
    END IF;

    SELECT * INTO v_appeal FROM moderation_appeals WHERE appeal_id = p_appeal;
    IF v_appeal.appeal_id IS NULL THEN RAISE EXCEPTION 'appeal not found'; END IF;
    IF v_appeal.status <> 'open' THEN
        RAISE EXCEPTION 'this appeal is already %', v_appeal.status;
    END IF;

    SELECT * INTO v_case FROM moderation_cases WHERE case_id = v_appeal.case_id;
    SELECT * INTO v_req FROM verification_requests
     WHERE request_id = v_appeal.verification_request_id;

    v_decider := COALESCE(v_case.decided_by, v_req.reviewed_by,
                          v_appeal.original_decider_id);
    IF v_decider IS NOT NULL AND v_decider = v_actor THEN
        RAISE EXCEPTION
          'forbidden: you took the decision being appealed; an appeal must be reviewed by someone else';
    END IF;
    IF v_appeal.appellant_id = v_actor THEN
        RAISE EXCEPTION 'forbidden: you cannot review your own appeal';
    END IF;

    IF p_outcome = 'overturned' THEN
        IF v_case.case_id IS NOT NULL THEN
            IF v_case.decision = 'content_removed' THEN
                IF v_case.target_type = 'post' THEN
                    UPDATE posts SET deleted_at = NULL WHERE post_id = v_case.target_id;
                ELSIF v_case.target_type = 'comment' THEN
                    UPDATE posts_comments SET deleted_at = NULL WHERE comment_id = v_case.target_id;
                ELSIF v_case.target_type = 'whisper' THEN
                    UPDATE whispers SET deleted_at = NULL WHERE whisper_id = v_case.target_id;
                ELSIF v_case.target_type = 'tribe_message' THEN
                    UPDATE tribe_messages SET deleted_at = NULL WHERE message_id = v_case.target_id;
                ELSIF v_case.target_type = 'dm_message' THEN
                    UPDATE chat_messages SET deleted_at = NULL WHERE message_id = v_case.target_id;
                END IF;
                v_reversed := jsonb_build_object('restored', v_case.target_type);

            ELSIF v_case.decision IN ('user_suspended', 'user_banned') THEN
                PERFORM admin_lift_suspension(v_case.subject_id,
                         'appeal ' || p_appeal::text || ' overturned');
                v_reversed := jsonb_build_object('suspension_lifted', true);
            END IF;

        ELSIF v_appeal.enforcement_notification_id IS NOT NULL
          AND EXISTS (SELECT 1 FROM private.member_communications c
                       WHERE c.notification_id = v_appeal.enforcement_notification_id
                         AND c.channel = 'warning') THEN
            UPDATE private.member_communications SET rescinded_at = now()
             WHERE notification_id = v_appeal.enforcement_notification_id
               AND channel = 'warning' AND rescinded_at IS NULL;
            v_reversed := jsonb_build_object('warning_rescinded', true);

        ELSIF v_appeal.enforcement_notification_id IS NOT NULL THEN
            PERFORM admin_lift_suspension(v_appeal.appellant_id,
                     'appeal ' || p_appeal::text || ' overturned');
            v_reversed := jsonb_build_object('suspension_lifted', true);

        ELSIF v_req.request_id IS NOT NULL THEN
            UPDATE verification_requests
               SET status = 'pending', reviewed_by = NULL, reviewed_at = NULL,
                   claimed_by = NULL, claimed_at = NULL, updated_at = now()
             WHERE request_id = v_req.request_id;
            v_reversed := jsonb_build_object('verification_reopened', true);
        END IF;
    END IF;

    UPDATE moderation_appeals
       SET status = p_outcome, reviewer_id = v_actor,
           reviewed_at = now(), review_note = p_note
     WHERE appeal_id = p_appeal;

    IF v_appeal.case_id IS NOT NULL THEN
        INSERT INTO moderation_case_events (case_id, kind, actor_id, actor_role, detail, note)
        SELECT v_appeal.case_id, 'note', v_actor, u.user_role::text,
               jsonb_build_object('event', 'appeal_' || p_outcome,
                                  'appeal_id', p_appeal, 'reversed', v_reversed),
               p_note
          FROM users u WHERE u.user_id = v_actor;
    END IF;

    PERFORM private.notify_enforcement(
        v_appeal.appellant_id,
        'appeal_' || p_outcome,
        v_appeal.case_id,
        v_case.policy_code,
        p_note,
        false
    );

    v_target_label := COALESCE(v_case.target_type,
                               CASE WHEN v_req.request_id IS NOT NULL
                                    THEN 'verification_request'
                                    ELSE 'account' END);

    PERFORM admin_log(
        'appeal.' || p_outcome, 'moderation_appeal', p_appeal, v_target_label,
        jsonb_build_object('original_decision', v_case.decision,
                           'original_decider', v_decider),
        jsonb_build_object('outcome', p_outcome, 'reversed', v_reversed),
        p_note, '{}'::jsonb
    );
END $function$;

SELECT public.record_migration('20261080090000', 'staff_can_reach_a_member');

NOTIFY pgrst, 'reload schema';
