-- Two corrections to the case model from 20261004090000, both found by
-- reading the code rather than the column names.
--
-- CORRECTION 1 — DMs are not encrypted, and that migration says they are.
--
-- chat_messages.encrypted_payload is a historical column name. The current
-- product stores server-readable plaintext there: the Flutter client reads the
-- column straight into a field it calls `plaintext` with no decryption step
-- (lib/data/services/supabase_backend.dart#_messageFromRow), and
-- private._server_content_write_guard runs server-side text-safety analysis
-- over the same value — which is only possible on plaintext. The guard's own
-- source says so: "Historical column name; the current product stores
-- server-readable plaintext for abuse review and must never label this value
-- as E2EE."
--
-- 20261004090000 asserted the opposite, and admin/README.md was edited to
-- claim its long-standing "private chats are server-readable under restricted
-- staff access" line contradicted the encryption. There was no contradiction:
-- the README was right and the migration was wrong. Both are corrected here
-- and in the README.
--
-- The consequence is a real design choice rather than a technical limit. A
-- reported DM is exactly the case the README sanctions review for, and a
-- harassment report about a DM is unreviewable without the message — the very
-- "no evidence preview" gap the case model exists to close. So the body IS
-- captured, but not into the evidence blob that admin_case_queue hands to
-- every staff role including support. It goes in a separate column behind a
-- narrower, logged accessor, which is what "access to highly sensitive
-- evidence must be separately logged and tightly scoped" asks for.
--
-- CORRECTION 2 — admin_decide_case recorded decisions without carrying them out.
--
-- A moderator choosing 'content_removed' got a resolved case, a decision
-- field, and an audit row saying the content was removed, while the content
-- stayed live. A record that claims an action nobody took is worse than no
-- record: it is what an appeal, a transparency report and a quality review
-- would all be read against. Decisions are now enacted in the same
-- transaction that records them.

-- =========================================================================
-- 1) Sensitive evidence, held separately from the queue projection
-- =========================================================================

ALTER TABLE public.moderation_cases
    ADD COLUMN IF NOT EXISTS sensitive_evidence JSONB;

COMMENT ON COLUMN public.moderation_cases.sensitive_evidence IS
  'Private-message bodies and similar. Deliberately excluded from admin_case_queue; read only through admin_read_case_sensitive_evidence, which logs the access.';

-- Rebuilt so dm_message captures the body into the sensitive channel. Returns
-- both halves; the caller decides which column each lands in.
CREATE OR REPLACE FUNCTION private.capture_case_evidence_split(
    p_target_type TEXT,
    p_target_id   UUID
) RETURNS TABLE (public_part JSONB, sensitive_part JSONB)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF p_target_type = 'dm_message' THEN
        RETURN QUERY
        SELECT jsonb_build_object(
                 'sender_id', m.sender_id, 'room_id', m.room_id,
                 'crisis_level', m.crisis_level, 'created_at', m.created_at,
                 'body_held_separately', true,
                 'body_length', length(COALESCE(m.encrypted_payload, ''))),
               jsonb_build_object('body', m.encrypted_payload)
          FROM public.chat_messages m WHERE m.message_id = p_target_id;
        IF NOT FOUND THEN
            RETURN QUERY SELECT jsonb_build_object('missing', true), NULL::jsonb;
        END IF;
    ELSE
        -- Everything else has no sensitive half; reuse the original capture.
        RETURN QUERY
        SELECT private.capture_case_evidence(p_target_type, p_target_id), NULL::jsonb;
    END IF;
END $$;

REVOKE ALL ON FUNCTION private.capture_case_evidence_split(TEXT, UUID)
    FROM PUBLIC, anon, authenticated;

-- Reading a private message body is a separate, narrower, logged act than
-- working the queue. support is excluded: it may triage, not read DMs.
CREATE OR REPLACE FUNCTION public.admin_read_case_sensitive_evidence(
    p_case   UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_case moderation_cases; v_actor UUID := auth.uid();
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT * INTO v_case FROM moderation_cases WHERE case_id = p_case;
    IF v_case.case_id IS NULL THEN RAISE EXCEPTION 'case not found'; END IF;
    IF v_case.sensitive_evidence IS NULL THEN
        RETURN NULL;
    END IF;

    -- Logged in both places on purpose: the case history is what an appeal or
    -- a quality review reads, and audit_log is what an access review reads.
    INSERT INTO moderation_case_events (case_id, kind, actor_id, actor_role, detail, note)
    SELECT p_case, 'evidence_accessed', v_actor, u.user_role::text,
           jsonb_build_object('target_type', v_case.target_type), p_reason
      FROM users u WHERE u.user_id = v_actor;

    PERFORM admin_log(
        'case.read_sensitive_evidence', 'moderation_case', p_case,
        v_case.target_type, NULL,
        jsonb_build_object('target_type', v_case.target_type),
        p_reason, '{}'::jsonb
    );

    RETURN v_case.sensitive_evidence;
END $$;

REVOKE ALL ON FUNCTION public.admin_read_case_sensitive_evidence(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_read_case_sensitive_evidence(UUID, TEXT) TO authenticated;

-- Use the split capture when a case opens.
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
    v_public    JSONB;
    v_sensitive JSONB;
BEGIN
    SELECT * INTO v_case FROM public.moderation_cases c
     WHERE c.target_type = p_target_type AND c.target_id = p_target_id;

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
        SELECT public_part, sensitive_part INTO v_public, v_sensitive
          FROM private.capture_case_evidence_split(p_target_type, p_target_id);

        INSERT INTO public.moderation_cases (
            target_type, target_id, subject_id, severity,
            evidence, sensitive_evidence, evidence_hash, evidence_captured_at,
            sla_due_at, report_count
        ) VALUES (
            p_target_type, p_target_id, p_subject_id, v_severity,
            v_public, v_sensitive,
            -- Hash covers both halves, so neither can be altered undetected.
            encode(extensions.digest(v_public::text || COALESCE(v_sensitive::text, ''), 'sha256'), 'hex'),
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

NOTIFY pgrst, 'reload schema';

-- =========================================================================
-- 2) Decisions are enacted, not just recorded
-- =========================================================================
-- Enactment reuses the existing RPCs where they exist — admin_set_post_deleted
-- and admin_set_user_status — rather than reimplementing removal and status
-- changes here. That keeps one path per capability and inherits their audit
-- rows and, for suspend/ban, their session revocation.
--
-- For comment/whisper/tribe_message/dm_message there is no admin removal RPC,
-- so deleted_at is set directly. That is safe against the content write
-- guards because those triggers are column-scoped — BEFORE INSERT OR UPDATE
-- OF content (OF encrypted_payload for chat_messages) — so a deleted_at-only
-- write does not fire them. It matters: the guard calls
-- private.assert_user_can_write(author) with no staff exemption, so if it did
-- fire, removing content would fail precisely when the author is already
-- suspended, which is when removal is most needed. Verified against a
-- suspended author before relying on it.

CREATE OR REPLACE FUNCTION public.admin_decide_case(
    p_case        UUID,
    p_decision    TEXT,
    p_policy_code TEXT DEFAULT NULL,
    p_note        TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before moderation_cases; v_actor UUID := auth.uid(); v_enacted JSONB := '{}'::jsonb;
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT * INTO v_before FROM moderation_cases WHERE case_id = p_case;
    IF v_before.case_id IS NULL THEN RAISE EXCEPTION 'case not found'; END IF;

    IF p_decision <> 'no_action' AND COALESCE(btrim(p_note), '') = '' THEN
        RAISE EXCEPTION 'a decision that affects a member requires a note';
    END IF;

    -- ---- enact, before recording that it happened ----
    IF p_decision = 'content_removed' THEN
        IF v_before.target_type = 'post' THEN
            PERFORM admin_set_post_deleted(v_before.target_id, true, p_note);
        ELSIF v_before.target_type = 'comment' THEN
            UPDATE posts_comments SET deleted_at = now()
             WHERE comment_id = v_before.target_id AND deleted_at IS NULL;
        ELSIF v_before.target_type = 'whisper' THEN
            UPDATE whispers SET deleted_at = now()
             WHERE whisper_id = v_before.target_id AND deleted_at IS NULL;
        ELSIF v_before.target_type = 'tribe_message' THEN
            UPDATE tribe_messages SET deleted_at = now()
             WHERE message_id = v_before.target_id AND deleted_at IS NULL;
        ELSIF v_before.target_type = 'dm_message' THEN
            UPDATE chat_messages SET deleted_at = now()
             WHERE message_id = v_before.target_id AND deleted_at IS NULL;
        ELSE
            -- Refuse rather than record a removal this function cannot carry
            -- out. A profile or a Tribe is not removed by deleting a row.
            RAISE EXCEPTION
              'content_removed is not implemented for target_type %; use a status decision or escalate',
              v_before.target_type;
        END IF;
        v_enacted := jsonb_build_object('removed', v_before.target_type);

    ELSIF p_decision IN ('user_suspended', 'user_banned', 'user_shadow_restricted') THEN
        IF v_before.subject_id IS NULL THEN
            RAISE EXCEPTION 'this case has no subject to act on';
        END IF;

        -- These map onto what the schema actually enforces, which is not what
        -- the names suggest. users_account_status_check allows only
        -- ('active','suspended','restricted') — there is no 'banned' and no
        -- 'shadow_banned' status. Per 0085_moderation_power_tools.sql a
        -- permanent ban IS account_status='suspended' with suspended_until
        -- NULL, and shadow restriction is the separate users.shadow_banned
        -- boolean, which is the value actually consulted by can_view_post_author
        -- and the search functions.
        --
        -- admin_set_user_status disagrees: it accepts 'banned' and
        -- 'shadow_banned', and the console's status dropdown offers both, so
        -- both have always failed on the CHECK constraint. That is a
        -- pre-existing bug in that RPC and that dropdown, not something this
        -- function should reproduce.
        IF p_decision = 'user_shadow_restricted' THEN
            PERFORM admin_set_shadow_ban(v_before.subject_id, true, p_note);
            v_enacted := jsonb_build_object('shadow_banned', true);
        ELSE
            PERFORM admin_set_user_status(v_before.subject_id, 'suspended', p_note);
            IF p_decision = 'user_banned' THEN
                -- NULL suspended_until is what makes it permanent.
                UPDATE users SET suspended_until = NULL, updated_at = now()
                 WHERE user_id = v_before.subject_id;
                v_enacted := jsonb_build_object('account_status', 'suspended',
                                                'permanent', true);
            ELSE
                v_enacted := jsonb_build_object('account_status', 'suspended');
            END IF;
        END IF;

    ELSIF p_decision = 'user_warned' THEN
        -- Recorded only, and said plainly: there is no platform-wide warning
        -- mechanism to deliver this. tribe_member_warnings is Tribe-scoped.
        -- The member-visible enforcement notice is still open P1 work, and
        -- until it exists this decision reaches nobody but staff.
        v_enacted := jsonb_build_object('warning_delivered', false,
                                        'reason', 'no member-facing notice mechanism yet');
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

    UPDATE reports
       SET is_resolved = true, resolved_at = now(), resolved_by = v_actor
     WHERE case_id = p_case AND is_resolved = false;

    INSERT INTO moderation_case_events (case_id, kind, actor_id, actor_role, detail, note)
    SELECT p_case, 'decided', v_actor, u.user_role::text,
           jsonb_build_object('decision', p_decision, 'policy_code', p_policy_code,
                              'enacted', v_enacted),
           p_note
      FROM users u WHERE u.user_id = v_actor;

    PERFORM admin_log(
        'case.decide', 'moderation_case', p_case, v_before.target_type,
        jsonb_build_object('status', v_before.status, 'decision', v_before.decision),
        jsonb_build_object('status', 'resolved', 'decision', p_decision,
                           'policy_code', p_policy_code, 'enacted', v_enacted),
        p_note, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_decide_case(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_decide_case(UUID, TEXT, TEXT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
