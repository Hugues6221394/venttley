-- A durable case model for moderation work.
--
-- Today a "case" is implicit: a row in `reports`, joined at render time to
-- whatever content still exists, with is_resolved as the only workflow state.
-- That has four consequences the console's own README lists as P0:
--
--   1. Reports about the same target are separate rows, so three reports about
--      one post are three pieces of work and three chances to decide
--      differently.
--   2. The queue can label a chat/comment target but usually has no evidence
--      to show, and offers real actions only when a joined post author is
--      present — the moderator is asked to decide with nothing in front of
--      them.
--   3. Evidence is read live. Content edited or deleted after the report is
--      simply gone by the time anybody looks, which is exactly what a bad
--      actor does next.
--   4. The 15/60-minute safety target is computed in the browser from
--      created_at. Nothing persists it, so nothing can alert on it, report on
--      it, or prove it was met.
--
-- This migration adds the case, its append-only history, and the link from
-- reports to cases. It deliberately does NOT change how the mobile client
-- files a report: a trigger opens or joins a case, so existing clients get
-- case-backed moderation without shipping an app release.

-- =========================================================================
-- 1) Cases
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.moderation_cases (
    case_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Polymorphic target. The list is wider than what can be reported today
    -- on purpose: the gap the README describes is that whole surfaces have no
    -- moderation path, and the case model should not be the thing blocking
    -- them when they get one.
    target_type TEXT NOT NULL CHECK (target_type IN (
        'post', 'comment', 'whisper', 'story', 'question', 'profile',
        'media', 'dm_message', 'tribe_message', 'chat_room', 'tribe'
    )),
    target_id   UUID NOT NULL,

    -- The member whose conduct is in question, resolved at open time. Kept
    -- even if the content is later deleted, which is when it matters most.
    subject_id  UUID REFERENCES public.users(user_id) ON DELETE SET NULL,

    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN (
        'open', 'in_review', 'awaiting_second_review',
        'resolved', 'escalated', 'reopened'
    )),
    severity TEXT NOT NULL DEFAULT 'normal' CHECK (severity IN (
        'low', 'normal', 'elevated', 'high', 'critical'
    )),

    -- Which written rule drove the outcome. Free text for now; the P2 item is
    -- versioned policy, and a code recorded here is what that will hang off.
    policy_code TEXT,

    assignee_id UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    assigned_at TIMESTAMPTZ,

    decision TEXT CHECK (decision IN (
        'no_action', 'content_removed', 'user_warned', 'user_suspended',
        'user_banned', 'user_shadow_restricted', 'escalated_external'
    )),
    decided_by    UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    decided_at    TIMESTAMPTZ,
    decision_note TEXT,

    -- Evidence as captured when the case opened, not as it reads now.
    evidence             JSONB NOT NULL DEFAULT '{}'::jsonb,
    evidence_hash        TEXT,
    evidence_captured_at TIMESTAMPTZ,

    -- Persisted SLA. sla_due_at is set from severity at open time;
    -- first_action_at is stamped by the first real moderator action.
    sla_due_at      TIMESTAMPTZ,
    sla_breached_at TIMESTAMPTZ,
    first_action_at TIMESTAMPTZ,

    -- Blocks the deletion/cleanup paths from destroying open-case material.
    legal_hold BOOLEAN NOT NULL DEFAULT false,

    report_count INT NOT NULL DEFAULT 0,

    opened_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- One case per target. This is the deduplication: further reports about
    -- the same thing join the case rather than opening another one.
    UNIQUE (target_type, target_id)
);

CREATE INDEX IF NOT EXISTS moderation_cases_queue_idx
    ON public.moderation_cases (status, severity, opened_at)
    WHERE status <> 'resolved';
CREATE INDEX IF NOT EXISTS moderation_cases_assignee_idx
    ON public.moderation_cases (assignee_id, status)
    WHERE assignee_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS moderation_cases_subject_idx
    ON public.moderation_cases (subject_id, opened_at DESC)
    WHERE subject_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS moderation_cases_sla_idx
    ON public.moderation_cases (sla_due_at)
    WHERE status <> 'resolved' AND sla_breached_at IS NULL;
CREATE INDEX IF NOT EXISTS moderation_cases_hold_idx
    ON public.moderation_cases (legal_hold) WHERE legal_hold;

ALTER TABLE public.moderation_cases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.moderation_cases FROM anon, authenticated;

DROP POLICY IF EXISTS "cases staff read" ON public.moderation_cases;
CREATE POLICY "cases staff read" ON public.moderation_cases FOR SELECT
    USING (public.is_staff(auth.uid(),
           ARRAY['super_admin','admin','moderator','support']));

-- =========================================================================
-- 2) Case history — append-only
-- =========================================================================
-- Every assignment, status change, escalation and decision. The audit_log
-- records that a privileged action happened; this records how one case moved,
-- which is what an appeal or a quality review actually needs to read.

CREATE TABLE IF NOT EXISTS public.moderation_case_events (
    event_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id    UUID NOT NULL REFERENCES public.moderation_cases(case_id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN (
        'opened', 'report_joined', 'assigned', 'unassigned', 'status_changed',
        'severity_changed', 'escalated', 'decided', 'reopened',
        'sla_breached', 'note', 'evidence_accessed', 'legal_hold_changed'
    )),
    actor_id   UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    actor_role TEXT,
    detail     JSONB NOT NULL DEFAULT '{}'::jsonb,
    note       TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS moderation_case_events_case_idx
    ON public.moderation_case_events (case_id, created_at);

ALTER TABLE public.moderation_case_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.moderation_case_events FROM anon, authenticated;

DROP POLICY IF EXISTS "case events staff read" ON public.moderation_case_events;
CREATE POLICY "case events staff read" ON public.moderation_case_events FOR SELECT
    USING (public.is_staff(auth.uid(),
           ARRAY['super_admin','admin','moderator','support']));

-- Same immutability contract as audit_log (0022): history that can be edited
-- is not history.
CREATE OR REPLACE FUNCTION private.case_events_append_only()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    RAISE EXCEPTION 'moderation_case_events rows are immutable (op: %)', TG_OP;
END $$;

REVOKE ALL ON FUNCTION private.case_events_append_only()
    FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS case_events_no_mutate ON public.moderation_case_events;
CREATE TRIGGER case_events_no_mutate
    BEFORE UPDATE OR DELETE ON public.moderation_case_events
    FOR EACH ROW EXECUTE FUNCTION private.case_events_append_only();

-- =========================================================================
-- 3) Reports link to cases
-- =========================================================================

ALTER TABLE public.reports
    ADD COLUMN IF NOT EXISTS case_id UUID
    REFERENCES public.moderation_cases(case_id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS reports_case_idx
    ON public.reports (case_id) WHERE case_id IS NOT NULL;

NOTIFY pgrst, 'reload schema';

-- =========================================================================
-- 4) Severity and SLA
-- =========================================================================
-- The 15/60-minute targets currently live in safety/page.tsx as a lookup on
-- two severities. Moving them here makes them queryable, alertable and
-- provable after the fact; leaving them in the browser meant the SLA existed
-- only while somebody had the tab open.

CREATE OR REPLACE FUNCTION private.case_severity(
    p_reason       TEXT,
    p_crisis_level TEXT DEFAULT NULL
) RETURNS TEXT
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
    SELECT CASE
        -- A crisis classification outranks the reporter's chosen reason: the
        -- reporter picked from a menu, the classifier saw the content.
        WHEN p_crisis_level = 'high'     THEN 'critical'
        WHEN p_reason = 'self_harm'      THEN 'critical'
        WHEN p_crisis_level = 'elevated' THEN 'high'
        WHEN p_reason IN ('violence', 'sexual_content') THEN 'high'
        WHEN p_reason IN ('hate', 'harassment', 'privacy') THEN 'elevated'
        WHEN p_reason = 'spam'           THEN 'low'
        ELSE 'normal'
    END;
$$;

CREATE OR REPLACE FUNCTION private.case_sla(p_severity TEXT)
RETURNS INTERVAL
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
    SELECT CASE p_severity
        WHEN 'critical' THEN interval '15 minutes'
        WHEN 'high'     THEN interval '30 minutes'
        WHEN 'elevated' THEN interval '60 minutes'
        WHEN 'normal'   THEN interval '24 hours'
        ELSE                 interval '72 hours'
    END;
$$;

REVOKE ALL ON FUNCTION private.case_severity(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.case_sla(TEXT) FROM PUBLIC, anon, authenticated;

-- =========================================================================
-- 5) Evidence capture
-- =========================================================================
-- Snapshot the content as it read when the case opened. Reading it live at
-- render time — what the console does today — means an edited or deleted
-- post shows the moderator nothing, and the record of what was actually
-- reported is gone.
--
-- DM and private-room bodies are deliberately NOT snapshotted, and it turns
-- out there is nothing to snapshot: chat_messages stores encrypted_payload,
-- not plaintext. That is worth stating plainly, because admin/README.md
-- currently says private chats are "server-readable under restricted staff
-- access", and the safety queue renders "(private DM — server-readable;
-- access restricted)" — both of which read as though a moderator could be
-- shown the text. Either the encryption or that copy is wrong, and a
-- moderation feature should not be the thing that quietly settles it.
-- The case records that the message exists, who sent it, and when.

CREATE OR REPLACE FUNCTION private.capture_case_evidence(
    p_target_type TEXT,
    p_target_id   UUID
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v JSONB;
BEGIN
    IF p_target_type = 'post' THEN
        SELECT jsonb_build_object(
                 'content', p.content, 'author_id', p.author_id,
                 'crisis_level', p.crisis_level, 'media_status', p.media_status,
                 'created_at', p.created_at, 'deleted_at', p.deleted_at)
          INTO v FROM public.posts p WHERE p.post_id = p_target_id;

    ELSIF p_target_type = 'comment' THEN
        SELECT jsonb_build_object(
                 'content', c.content, 'author_id', c.author_id,
                 'post_id', c.post_id, 'created_at', c.created_at)
          INTO v FROM public.posts_comments c WHERE c.comment_id = p_target_id;

    ELSIF p_target_type = 'whisper' THEN
        SELECT jsonb_build_object(
                 'author_id', w.author_id, 'crisis_level', w.crisis_level,
                 'media_status', w.media_status, 'created_at', w.created_at,
                 'deleted_at', w.deleted_at)
          INTO v FROM public.whispers w WHERE w.whisper_id = p_target_id;

    ELSIF p_target_type = 'tribe_message' THEN
        SELECT jsonb_build_object(
                 'content', m.content, 'sender_id', m.sender_id,
                 'tribe_id', m.tribe_id, 'crisis_level', m.crisis_level,
                 'created_at', m.created_at)
          INTO v FROM public.tribe_messages m WHERE m.message_id = p_target_id;

    ELSIF p_target_type = 'dm_message' THEN
        -- Metadata only, and not by choice alone: chat_messages holds an
        -- encrypted_payload, not plaintext, so there is no body here to
        -- snapshot even if it were wanted. Ciphertext length is not recorded
        -- either — it approximates the plaintext length.
        SELECT jsonb_build_object(
                 'sender_id', m.sender_id, 'room_id', m.room_id,
                 'crisis_level', m.crisis_level, 'created_at', m.created_at,
                 'body_withheld', true, 'body_encrypted', true)
          INTO v FROM public.chat_messages m WHERE m.message_id = p_target_id;

    ELSIF p_target_type = 'chat_room' THEN
        SELECT jsonb_build_object('room_id', p_target_id, 'body_withheld', true)
          INTO v;

    ELSIF p_target_type = 'tribe' THEN
        SELECT jsonb_build_object(
                 'name', t.name, 'slug', t.slug, 'keeper_id', t.keeper_id,
                 'description', t.description)
          INTO v FROM public.tribes t WHERE t.tribe_id = p_target_id;

    ELSIF p_target_type = 'profile' THEN
        SELECT jsonb_build_object(
                 'pseudonym', u.anonymous_pseudonym, 'display_name', u.display_name,
                 'account_status', u.account_status)
          INTO v FROM public.users u WHERE u.user_id = p_target_id;
    END IF;

    -- A target that has already vanished is itself worth recording.
    RETURN COALESCE(v, jsonb_build_object('missing', true));
END $$;

REVOKE ALL ON FUNCTION private.capture_case_evidence(TEXT, UUID)
    FROM PUBLIC, anon, authenticated;

-- =========================================================================
-- 6) Open or join a case
-- =========================================================================

CREATE OR REPLACE FUNCTION private.open_or_join_case(
    p_target_type TEXT,
    p_target_id   UUID,
    p_subject_id  UUID,
    p_reason      TEXT,
    p_report_id   UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_case      public.moderation_cases;
    v_crisis    TEXT;
    v_severity  TEXT;
    v_evidence  JSONB;
BEGIN
    SELECT * INTO v_case FROM public.moderation_cases c
     WHERE c.target_type = p_target_type AND c.target_id = p_target_id;

    -- Let the classifier's read of the content raise severity above whatever
    -- the reporter picked.
    IF p_target_type = 'post' THEN
        SELECT crisis_level INTO v_crisis FROM public.posts WHERE post_id = p_target_id;
    ELSIF p_target_type = 'whisper' THEN
        SELECT crisis_level INTO v_crisis FROM public.whispers WHERE whisper_id = p_target_id;
    ELSIF p_target_type = 'tribe_message' THEN
        SELECT crisis_level INTO v_crisis FROM public.tribe_messages WHERE message_id = p_target_id;
    ELSIF p_target_type = 'dm_message' THEN
        SELECT crisis_level INTO v_crisis FROM public.chat_messages WHERE message_id = p_target_id;
    END IF;

    v_severity := private.case_severity(p_reason, v_crisis);

    IF v_case.case_id IS NULL THEN
        v_evidence := private.capture_case_evidence(p_target_type, p_target_id);

        INSERT INTO public.moderation_cases (
            target_type, target_id, subject_id, severity,
            evidence, evidence_hash, evidence_captured_at,
            sla_due_at, report_count
        ) VALUES (
            p_target_type, p_target_id, p_subject_id, v_severity,
            v_evidence,
            encode(extensions.digest(v_evidence::text, 'sha256'), 'hex'),
            now(),
            now() + private.case_sla(v_severity),
            CASE WHEN p_report_id IS NULL THEN 0 ELSE 1 END
        )
        RETURNING * INTO v_case;

        INSERT INTO public.moderation_case_events (case_id, kind, detail)
        VALUES (v_case.case_id, 'opened',
                jsonb_build_object('severity', v_severity, 'reason', p_reason,
                                   'sla_due_at', v_case.sla_due_at));
    ELSE
        -- Existing case. More reports mean more signal, so a later report may
        -- raise severity — and raising it must pull the SLA in, or a case that
        -- became critical would keep a lenient deadline set when it looked
        -- routine. Severity is never lowered here: a second, milder report
        -- does not undo the first one's read of the situation.
        IF private.case_sla(v_severity) < private.case_sla(v_case.severity) THEN
            UPDATE public.moderation_cases
               SET severity   = v_severity,
                   sla_due_at = LEAST(sla_due_at, opened_at + private.case_sla(v_severity)),
                   updated_at = now()
             WHERE case_id = v_case.case_id;

            INSERT INTO public.moderation_case_events (case_id, kind, detail)
            VALUES (v_case.case_id, 'severity_changed',
                    jsonb_build_object('from', v_case.severity, 'to', v_severity,
                                       'cause', 'additional report'));
        END IF;

        UPDATE public.moderation_cases
           SET report_count = report_count + CASE WHEN p_report_id IS NULL THEN 0 ELSE 1 END,
               -- A new report on a case somebody already closed reopens it.
               status     = CASE WHEN status = 'resolved' THEN 'reopened' ELSE status END,
               updated_at = now()
         WHERE case_id = v_case.case_id;

        IF p_report_id IS NOT NULL THEN
            INSERT INTO public.moderation_case_events (case_id, kind, detail)
            VALUES (v_case.case_id, 'report_joined',
                    jsonb_build_object('report_id', p_report_id, 'reason', p_reason));
        END IF;
    END IF;

    RETURN v_case.case_id;
END $$;

REVOKE ALL ON FUNCTION private.open_or_join_case(TEXT, UUID, UUID, TEXT, UUID)
    FROM PUBLIC, anon, authenticated;

-- =========================================================================
-- 7) Every report becomes case work, without an app release
-- =========================================================================

CREATE OR REPLACE FUNCTION private.report_opens_case()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_type    TEXT;
    v_target  UUID;
    v_subject UUID;
    v_case    UUID;
BEGIN
    IF NEW.post_id IS NOT NULL THEN
        v_type := 'post'; v_target := NEW.post_id;
        SELECT author_id INTO v_subject FROM public.posts WHERE post_id = NEW.post_id;
    ELSIF NEW.target_comment_id IS NOT NULL THEN
        v_type := 'comment'; v_target := NEW.target_comment_id;
        SELECT author_id INTO v_subject FROM public.posts_comments WHERE comment_id = NEW.target_comment_id;
    ELSIF NEW.target_tribe_message_id IS NOT NULL THEN
        v_type := 'tribe_message'; v_target := NEW.target_tribe_message_id;
        SELECT sender_id INTO v_subject FROM public.tribe_messages WHERE message_id = NEW.target_tribe_message_id;
    ELSIF NEW.target_chat_message_id IS NOT NULL THEN
        v_type := 'dm_message'; v_target := NEW.target_chat_message_id;
        SELECT sender_id INTO v_subject FROM public.chat_messages WHERE message_id = NEW.target_chat_message_id;
    ELSIF NEW.target_room_id IS NOT NULL THEN
        v_type := 'chat_room'; v_target := NEW.target_room_id;
    ELSE
        -- reports_one_target should make this unreachable; if it ever is
        -- reached, losing the report is worse than having no case.
        RETURN NEW;
    END IF;

    v_case := private.open_or_join_case(v_type, v_target, v_subject, NEW.reason, NEW.report_id);
    NEW.case_id := v_case;
    RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION private.report_opens_case() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS reports_open_case ON public.reports;
CREATE TRIGGER reports_open_case
    BEFORE INSERT ON public.reports
    FOR EACH ROW EXECUTE FUNCTION private.report_opens_case();

NOTIFY pgrst, 'reload schema';

-- =========================================================================
-- 8) Staff RPCs
-- =========================================================================
-- Same contract as every other admin_* function: is_staff() gate, state
-- check, mutation, and the audit write in one transaction.

-- Claim a case, or hand it to someone else.
CREATE OR REPLACE FUNCTION public.admin_assign_case(
    p_case     UUID,
    p_assignee UUID DEFAULT NULL,
    p_reason   TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before moderation_cases; v_actor UUID := auth.uid();
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT * INTO v_before FROM moderation_cases WHERE case_id = p_case;
    IF v_before.case_id IS NULL THEN RAISE EXCEPTION 'case not found'; END IF;

    -- Assigning to somebody who cannot work the queue would silently park the
    -- case with nobody accountable for it.
    IF p_assignee IS NOT NULL
       AND NOT is_staff(p_assignee, ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'assignee is not a moderator';
    END IF;

    UPDATE moderation_cases
       SET assignee_id     = p_assignee,
           assigned_at     = CASE WHEN p_assignee IS NULL THEN NULL ELSE now() END,
           status          = CASE
                               WHEN p_assignee IS NULL THEN status
                               WHEN status IN ('open', 'reopened') THEN 'in_review'
                               ELSE status
                             END,
           first_action_at = COALESCE(first_action_at, now()),
           updated_at      = now()
     WHERE case_id = p_case;

    INSERT INTO moderation_case_events (case_id, kind, actor_id, actor_role, detail, note)
    SELECT p_case,
           CASE WHEN p_assignee IS NULL THEN 'unassigned' ELSE 'assigned' END,
           v_actor, u.user_role::text,
           jsonb_build_object('from', v_before.assignee_id, 'to', p_assignee),
           p_reason
      FROM users u WHERE u.user_id = v_actor;

    PERFORM admin_log(
        'case.assign', 'moderation_case', p_case, v_before.target_type,
        jsonb_build_object('assignee_id', v_before.assignee_id),
        jsonb_build_object('assignee_id', p_assignee),
        p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_assign_case(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_assign_case(UUID, UUID, TEXT) TO authenticated;

-- Record the outcome. This is the moment the case stops being work.
CREATE OR REPLACE FUNCTION public.admin_decide_case(
    p_case        UUID,
    p_decision    TEXT,
    p_policy_code TEXT DEFAULT NULL,
    p_note        TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before moderation_cases; v_actor UUID := auth.uid();
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT * INTO v_before FROM moderation_cases WHERE case_id = p_case;
    IF v_before.case_id IS NULL THEN RAISE EXCEPTION 'case not found'; END IF;

    -- A decision is the thing an appeal argues with, so it needs a reason
    -- attached from the start rather than reconstructed later.
    IF p_decision <> 'no_action' AND COALESCE(btrim(p_note), '') = '' THEN
        RAISE EXCEPTION 'a decision that affects a member requires a note';
    END IF;

    UPDATE moderation_cases
       SET decision        = p_decision,
           decided_by      = v_actor,
           decided_at      = now(),
           decision_note   = p_note,
           policy_code     = COALESCE(p_policy_code, policy_code),
           status          = 'resolved',
           first_action_at = COALESCE(first_action_at, now()),
           updated_at      = now()
     WHERE case_id = p_case;

    -- The reports that fed this case are the same piece of work; closing the
    -- case without closing them would leave them sitting in the old queue.
    UPDATE reports
       SET is_resolved = true, resolved_at = now(), resolved_by = v_actor
     WHERE case_id = p_case AND is_resolved = false;

    INSERT INTO moderation_case_events (case_id, kind, actor_id, actor_role, detail, note)
    SELECT p_case, 'decided', v_actor, u.user_role::text,
           jsonb_build_object('decision', p_decision, 'policy_code', p_policy_code),
           p_note
      FROM users u WHERE u.user_id = v_actor;

    PERFORM admin_log(
        'case.decide', 'moderation_case', p_case, v_before.target_type,
        jsonb_build_object('status', v_before.status, 'decision', v_before.decision),
        jsonb_build_object('status', 'resolved', 'decision', p_decision,
                           'policy_code', p_policy_code),
        p_note, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_decide_case(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_decide_case(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- Escalate, put back in the queue, or send for a second pair of eyes.
CREATE OR REPLACE FUNCTION public.admin_set_case_status(
    p_case   UUID,
    p_status TEXT,
    p_note   TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before moderation_cases; v_actor UUID := auth.uid();
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    IF p_status NOT IN ('open','in_review','awaiting_second_review','escalated','reopened') THEN
        -- 'resolved' is reachable only through admin_decide_case, so a case
        -- can never be closed without a recorded decision.
        RAISE EXCEPTION 'status % must be set through admin_decide_case', p_status;
    END IF;

    SELECT * INTO v_before FROM moderation_cases WHERE case_id = p_case;
    IF v_before.case_id IS NULL THEN RAISE EXCEPTION 'case not found'; END IF;

    UPDATE moderation_cases
       SET status          = p_status,
           first_action_at = COALESCE(first_action_at, now()),
           updated_at      = now()
     WHERE case_id = p_case;

    INSERT INTO moderation_case_events (case_id, kind, actor_id, actor_role, detail, note)
    SELECT p_case,
           CASE WHEN p_status = 'escalated' THEN 'escalated'
                WHEN p_status = 'reopened'  THEN 'reopened'
                ELSE 'status_changed' END,
           v_actor, u.user_role::text,
           jsonb_build_object('from', v_before.status, 'to', p_status), p_note
      FROM users u WHERE u.user_id = v_actor;

    PERFORM admin_log(
        'case.status', 'moderation_case', p_case, v_before.target_type,
        jsonb_build_object('status', v_before.status),
        jsonb_build_object('status', p_status), p_note, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_set_case_status(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_case_status(UUID, TEXT, TEXT) TO authenticated;

-- Legal hold. Cleanup and account deletion must not destroy open-case
-- material; this is the flag those paths check.
CREATE OR REPLACE FUNCTION public.admin_set_case_legal_hold(
    p_case   UUID,
    p_hold   BOOLEAN,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before moderation_cases; v_actor UUID := auth.uid();
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden: legal hold is super_admin or admin';
    END IF;
    IF COALESCE(btrim(p_reason), '') = '' THEN
        RAISE EXCEPTION 'legal hold requires a reason';
    END IF;

    SELECT * INTO v_before FROM moderation_cases WHERE case_id = p_case;
    IF v_before.case_id IS NULL THEN RAISE EXCEPTION 'case not found'; END IF;

    UPDATE moderation_cases
       SET legal_hold = p_hold, updated_at = now() WHERE case_id = p_case;

    INSERT INTO moderation_case_events (case_id, kind, actor_id, actor_role, detail, note)
    SELECT p_case, 'legal_hold_changed', v_actor, u.user_role::text,
           jsonb_build_object('from', v_before.legal_hold, 'to', p_hold), p_reason
      FROM users u WHERE u.user_id = v_actor;

    PERFORM admin_log(
        'case.legal_hold', 'moderation_case', p_case, v_before.target_type,
        jsonb_build_object('legal_hold', v_before.legal_hold),
        jsonb_build_object('legal_hold', p_hold), p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_set_case_legal_hold(UUID, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_case_legal_hold(UUID, BOOLEAN, TEXT) TO authenticated;

-- The queue, ordered the way it should be worked: breached first, then by
-- how close the deadline is.
CREATE OR REPLACE FUNCTION public.admin_case_queue(
    p_status   TEXT DEFAULT NULL,
    p_assignee UUID DEFAULT NULL,
    p_limit    INT  DEFAULT 200
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
    evidence       JSONB,
    sla_due_at     TIMESTAMPTZ,
    sla_breached   BOOLEAN,
    minutes_to_due NUMERIC,
    legal_hold     BOOLEAN,
    opened_at      TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator','support']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    RETURN QUERY
    SELECT c.case_id, c.target_type, c.target_id, c.subject_id,
           su.anonymous_pseudonym::text, c.status, c.severity,
           c.assignee_id, au.anonymous_pseudonym::text, c.report_count,
           c.evidence, c.sla_due_at,
           (c.sla_breached_at IS NOT NULL
            OR (c.status <> 'resolved' AND c.sla_due_at < now())) AS sla_breached,
           round(EXTRACT(EPOCH FROM (c.sla_due_at - now())) / 60.0, 1),
           c.legal_hold, c.opened_at
      FROM moderation_cases c
      LEFT JOIN users su ON su.user_id = c.subject_id
      LEFT JOIN users au ON au.user_id = c.assignee_id
     WHERE (p_status IS NULL
            OR (p_status = 'unresolved' AND c.status <> 'resolved')
            OR c.status = p_status)
       AND (p_assignee IS NULL OR c.assignee_id = p_assignee)
     ORDER BY (c.status <> 'resolved' AND c.sla_due_at < now()) DESC,
              CASE c.severity
                WHEN 'critical' THEN 0 WHEN 'high' THEN 1
                WHEN 'elevated' THEN 2 WHEN 'normal' THEN 3 ELSE 4 END,
              c.sla_due_at
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
END $$;

REVOKE ALL ON FUNCTION public.admin_case_queue(TEXT, UUID, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_case_queue(TEXT, UUID, INT) TO authenticated;

-- =========================================================================
-- 9) SLA breach sweep
-- =========================================================================
-- Stamps the breach so it survives as a fact rather than being recomputed
-- from now() every time somebody looks. Cron-scheduled below; the queue view
-- above still compares against now() so a breach shows immediately even
-- between runs.

CREATE OR REPLACE FUNCTION private.sweep_case_sla_breaches()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_count INT;
BEGIN
    WITH newly AS (
        UPDATE public.moderation_cases
           SET sla_breached_at = now(), updated_at = now()
         WHERE status <> 'resolved'
           AND sla_breached_at IS NULL
           AND sla_due_at < now()
        RETURNING case_id, severity, sla_due_at
    )
    INSERT INTO public.moderation_case_events (case_id, kind, detail)
    SELECT case_id, 'sla_breached',
           jsonb_build_object('severity', severity, 'due_at', sla_due_at)
      FROM newly;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION private.sweep_case_sla_breaches()
    FROM PUBLIC, anon, authenticated;

SELECT cron.schedule(
    'moderation_case_sla_sweep',
    '* * * * *',
    $cron$SELECT private.sweep_case_sla_breaches();$cron$
)
WHERE NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'moderation_case_sla_sweep'
);

-- =========================================================================
-- 10) Backfill
-- =========================================================================
-- Open cases for reports that are still live work. Resolved reports are
-- deliberately left alone: evidence captured now would carry today's
-- timestamp and today's content for a decision taken months ago, which is
-- worse than no snapshot at all.

DO $backfill$
DECLARE r RECORD; v_type TEXT; v_target UUID; v_subject UUID; v_case UUID;
BEGIN
    FOR r IN
        SELECT * FROM public.reports
         WHERE is_resolved = false AND case_id IS NULL
         ORDER BY created_at
    LOOP
        v_type := NULL; v_target := NULL; v_subject := NULL;

        IF r.post_id IS NOT NULL THEN
            v_type := 'post'; v_target := r.post_id;
            SELECT author_id INTO v_subject FROM public.posts WHERE post_id = r.post_id;
        ELSIF r.target_comment_id IS NOT NULL THEN
            v_type := 'comment'; v_target := r.target_comment_id;
            SELECT author_id INTO v_subject FROM public.posts_comments WHERE comment_id = r.target_comment_id;
        ELSIF r.target_tribe_message_id IS NOT NULL THEN
            v_type := 'tribe_message'; v_target := r.target_tribe_message_id;
            SELECT sender_id INTO v_subject FROM public.tribe_messages WHERE message_id = r.target_tribe_message_id;
        ELSIF r.target_chat_message_id IS NOT NULL THEN
            v_type := 'dm_message'; v_target := r.target_chat_message_id;
            SELECT sender_id INTO v_subject FROM public.chat_messages WHERE message_id = r.target_chat_message_id;
        ELSIF r.target_room_id IS NOT NULL THEN
            v_type := 'chat_room'; v_target := r.target_room_id;
        END IF;

        IF v_type IS NOT NULL THEN
            v_case := private.open_or_join_case(v_type, v_target, v_subject, r.reason, r.report_id);
            UPDATE public.reports SET case_id = v_case WHERE report_id = r.report_id;
        END IF;
    END LOOP;
END
$backfill$;

-- The ledger has to be able to tell whether this ran.
SELECT public.record_migration(
  '20261004090000', 'moderation_case_model'
);

NOTIFY pgrst, 'reload schema';
