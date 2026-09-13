-- Appealing a suspension, a ban, or a refused verification.
--
-- 20261007090000 built appeals around moderation cases, and every other
-- enforcement path was left telling the member they could appeal with nothing
-- behind it:
--
--   * admin_set_user_status and admin_suspend_user_ladder send
--     'account_suspended' / 'account_restricted' with p_appealable => true and
--     p_case => NULL. moderation_appeals keys on a case or a verification
--     request, and submit_appeal takes a case. So the heaviest action the
--     platform can take — suspension, and a permanent ban, which is a
--     suspension with no end date — was the one action with no route to
--     contest it.
--   * admin_review_verification sends 'verification_denied' with
--     p_appealable => NOT p_approve. The table has had a
--     verification_request_id column since the beginning and nothing ever
--     wrote to it, because the notice carried no request id and no function
--     existed to file one.
--
-- Two defects surfaced while reading the code this builds on, both latent only
-- because non-case appeals could not be created:
--
--   * admin_decide_appeal inserts into moderation_case_events with
--     v_appeal.case_id unconditionally, and that column is NOT NULL. Deciding
--     a verification appeal would have failed on a null-constraint violation —
--     a moderator seeing a raw Postgres error on an appeal they cannot then
--     resolve.
--   * The independence check — the property this whole feature rests on, that
--     the reviewer is not the person being appealed — reads
--     v_case.decided_by. For an appeal with no case that is NULL, so the check
--     passes for everyone, including the moderator who took the decision. An
--     appeal reviewed by its own author is worse than no appeal, because it
--     produces a record saying the decision was independently confirmed.
--
-- The shape here: an appeal's subject becomes one of three, and the notice the
-- member received is itself appealable for account-level actions. That is the
-- honest object — an account suspension has no case row, and the notification
-- is the decision as far as the member is concerned. It carries the date the
-- 30-day window runs from, and now a reference to the audit entry, so who
-- decided can be established without putting staff identity in front of the
-- member.

BEGIN;

-- =========================================================================
-- 1) The notice can point back at the decision
-- =========================================================================
-- Dropped rather than replaced: adding parameters to a function changes its
-- signature, and CREATE OR REPLACE would leave the six-argument version in
-- place and make every existing call ambiguous. The defaults mean the six
-- existing call sites keep resolving here unchanged.

DROP FUNCTION IF EXISTS private.notify_enforcement(UUID, TEXT, UUID, TEXT, TEXT, BOOLEAN);

CREATE OR REPLACE FUNCTION private.notify_enforcement(
    p_user     UUID,
    p_action   TEXT,
    p_case     UUID DEFAULT NULL,
    p_policy   TEXT DEFAULT NULL,
    p_reason   TEXT DEFAULT NULL,
    p_appealable BOOLEAN DEFAULT true,
    -- The audit_log entry for the decision. An opaque id to the member — the
    -- audit log is staff-only — and the way admin_decide_appeal establishes
    -- who took a decision that has no case row. Consistent with case_id, which
    -- has always been an internal id sitting in the member's payload.
    p_decision_ref UUID DEFAULT NULL,
    p_request  UUID DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF p_user IS NULL THEN RETURN; END IF;

    INSERT INTO public.notifications (user_id, kind, payload)
    VALUES (
        p_user,
        'moderation_action',
        jsonb_strip_nulls(jsonb_build_object(
            'action',     p_action,
            'case_id',    p_case,
            'policy',     p_policy,
            -- The moderator's note is written for the member to read. It is
            -- the only explanation they get, and what an appeal argues with.
            'reason',     p_reason,
            'appealable', p_appealable,
            'decision_ref', p_decision_ref,
            'verification_request_id', p_request,
            'decided_at', now()
        ))
    );
END $$;

REVOKE ALL ON FUNCTION private.notify_enforcement(UUID, TEXT, UUID, TEXT, TEXT, BOOLEAN, UUID, UUID)
    FROM PUBLIC, anon, authenticated;

-- =========================================================================
-- 2) A third kind of subject
-- =========================================================================

ALTER TABLE public.moderation_appeals
    ADD COLUMN IF NOT EXISTS enforcement_notification_id UUID
        REFERENCES public.notifications(notification_id) ON DELETE CASCADE,
    -- Not a subject: an integrity field. Resolved when the appeal is filed so
    -- the independence check has something to compare against for a decision
    -- with no case row. Null for case appeals, which read decided_by.
    ADD COLUMN IF NOT EXISTS original_decider_id UUID
        REFERENCES public.users(user_id) ON DELETE SET NULL,
    -- Likewise captured at filing. Overturning a verification appeal clears
    -- reviewed_at to put the application back in the queue, which erased the
    -- only record of when the refusal happened — so a decided appeal showed a
    -- blank date in the console, for a decision that demonstrably had one.
    ADD COLUMN IF NOT EXISTS original_decided_at TIMESTAMPTZ;

ALTER TABLE public.moderation_appeals DROP CONSTRAINT IF EXISTS appeals_one_subject;
ALTER TABLE public.moderation_appeals ADD CONSTRAINT appeals_one_subject CHECK (
    (CASE WHEN case_id IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN verification_request_id IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN enforcement_notification_id IS NOT NULL THEN 1 ELSE 0 END) = 1
);

-- Same rule as the other two: one open at a time, and "already heard is
-- final" is enforced in the submit functions because a partial index on
-- status='open' cannot express it.
CREATE UNIQUE INDEX IF NOT EXISTS appeals_one_open_per_notice
    ON public.moderation_appeals (enforcement_notification_id)
    WHERE enforcement_notification_id IS NOT NULL AND status = 'open';

-- =========================================================================
-- 3) Filing one
-- =========================================================================

-- What is being appealed is the notice the member received. They have it, they
-- can read it, and it is the only account the platform gave them of what was
-- decided.
CREATE OR REPLACE FUNCTION public.submit_account_appeal(
    p_notification UUID,
    p_statement    TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid     UUID := auth.uid();
    v_row     notifications;
    v_payload JSONB;
    v_decided TIMESTAMPTZ;
    v_decider UUID;
    v_id      UUID;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT * INTO v_row FROM notifications WHERE notification_id = p_notification;
    IF v_row.notification_id IS NULL THEN
        RAISE EXCEPTION 'notice not found';
    END IF;
    -- Only your own notice. A notification id in someone else's hands must not
    -- become a way to act on a decision about a third party.
    IF v_row.user_id IS DISTINCT FROM v_uid THEN
        RAISE EXCEPTION 'forbidden: you can only appeal a decision about you';
    END IF;
    IF v_row.kind <> 'moderation_action' THEN
        RAISE EXCEPTION 'that notice is not a moderation decision';
    END IF;

    v_payload := v_row.payload;

    IF COALESCE(v_payload->>'appealable', 'false') <> 'true' THEN
        RAISE EXCEPTION 'this decision is not appealable';
    END IF;
    -- A case-backed decision goes through submit_appeal, which can read the
    -- case, reverse the removal, and record in the case history. Silently
    -- accepting it here would create a second, weaker appeal path for the same
    -- decision.
    IF v_payload->>'case_id' IS NOT NULL THEN
        RAISE EXCEPTION
          'this decision belongs to a moderation case; appeal it with submit_appeal';
    END IF;
    IF v_payload->>'verification_request_id' IS NOT NULL THEN
        RAISE EXCEPTION
          'this is a verification decision; appeal it with submit_verification_appeal';
    END IF;

    v_decided := (v_payload->>'decided_at')::TIMESTAMPTZ;
    IF v_decided IS NULL THEN
        RAISE EXCEPTION 'this notice carries no decision date, so no appeal window can be established';
    END IF;
    IF v_decided < now() - interval '30 days' THEN
        RAISE EXCEPTION 'the 30-day window to appeal this decision has passed';
    END IF;

    IF EXISTS (
        SELECT 1 FROM moderation_appeals a
         WHERE a.enforcement_notification_id = p_notification
           AND a.appellant_id = v_uid
           AND a.status IN ('upheld', 'overturned')
    ) THEN
        RAISE EXCEPTION
          'this decision has already been through appeal; that outcome is final at this tier';
    END IF;

    -- Who took it, for the independence check later. Resolved now rather than
    -- at review time because the audit entry is the record of the decision and
    -- is immutable; looking it up later by guessing at timestamps would not be.
    SELECT al.actor_id INTO v_decider
      FROM audit_log al
     WHERE al.audit_id = (v_payload->>'decision_ref')::UUID;

    INSERT INTO moderation_appeals
        (enforcement_notification_id, appellant_id, statement,
         original_decider_id, original_decided_at)
    VALUES (p_notification, v_uid, p_statement, v_decider, v_decided)
    RETURNING appeal_id INTO v_id;

    RETURN v_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'you already have an appeal open on this decision';
END $$;

REVOKE ALL ON FUNCTION public.submit_account_appeal(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_account_appeal(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.submit_verification_appeal(
    p_request   UUID,
    p_statement TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_req verification_requests;
    v_id  UUID;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT * INTO v_req FROM verification_requests WHERE request_id = p_request;
    IF v_req.request_id IS NULL THEN RAISE EXCEPTION 'request not found'; END IF;
    IF v_req.user_id IS DISTINCT FROM v_uid THEN
        RAISE EXCEPTION 'forbidden: only the applicant may appeal a verification decision';
    END IF;
    IF v_req.status NOT IN ('rejected', 'revoked') THEN
        RAISE EXCEPTION 'there is nothing to appeal: this application is %', v_req.status;
    END IF;
    IF v_req.reviewed_at IS NULL THEN
        RAISE EXCEPTION 'this application has not been decided yet';
    END IF;
    IF v_req.reviewed_at < now() - interval '30 days' THEN
        RAISE EXCEPTION 'the 30-day window to appeal this decision has passed';
    END IF;

    IF EXISTS (
        SELECT 1 FROM moderation_appeals a
         WHERE a.verification_request_id = p_request
           AND a.appellant_id = v_uid
           AND a.status IN ('upheld', 'overturned')
    ) THEN
        RAISE EXCEPTION
          'this decision has already been through appeal; that outcome is final at this tier';
    END IF;

    INSERT INTO moderation_appeals
        (verification_request_id, appellant_id, statement,
         original_decider_id, original_decided_at)
    VALUES (p_request, v_uid, p_statement, v_req.reviewed_by, v_req.reviewed_at)
    RETURNING appeal_id INTO v_id;

    RETURN v_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'you already have an appeal open on this decision';
END $$;

REVOKE ALL ON FUNCTION public.submit_verification_appeal(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_verification_appeal(UUID, TEXT) TO authenticated;

-- =========================================================================
-- 4) Deciding one
-- =========================================================================
-- Rewritten for three subjects, and for the two defects above.

CREATE OR REPLACE FUNCTION public.admin_decide_appeal(
    p_appeal  UUID,
    p_outcome TEXT,
    p_note    TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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

    -- Independence, for every kind of appeal. Reading only v_case.decided_by
    -- meant an appeal with no case had nobody to compare against, so the check
    -- silently passed — including for the moderator whose decision it was.
    v_decider := COALESCE(v_case.decided_by, v_req.reviewed_by,
                          v_appeal.original_decider_id);
    IF v_decider IS NOT NULL AND v_decider = v_actor THEN
        RAISE EXCEPTION
          'forbidden: you took the decision being appealed; an appeal must be reviewed by someone else';
    END IF;
    IF v_appeal.appellant_id = v_actor THEN
        RAISE EXCEPTION 'forbidden: you cannot review your own appeal';
    END IF;

    -- Overturning has to undo the thing. An overturned-then-nothing-happens
    -- appeal is the same defect as a decision that records without enacting:
    -- the record says the member won and their content is still gone.
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

        ELSIF v_appeal.enforcement_notification_id IS NOT NULL THEN
            -- An account-level action. Reuse the lift path so the
            -- reinstatement is audited like any other status change, and so
            -- the member is told they are back rather than having to discover
            -- it by trying to log in.
            PERFORM admin_lift_suspension(v_appeal.appellant_id,
                     'appeal ' || p_appeal::text || ' overturned');
            v_reversed := jsonb_build_object('suspension_lifted', true);

        ELSIF v_req.request_id IS NOT NULL THEN
            -- Deliberately not an approval. Overturning says the refusal was
            -- wrong, not that the evidence has been checked and accepted —
            -- auto-approving here would grant a badge nobody reviewed. It goes
            -- back in the queue for a fresh look by someone else.
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

    -- Only a case has a case history. moderation_case_events.case_id is NOT
    -- NULL, so the unconditional insert this replaces would have aborted the
    -- whole decision for any appeal without one.
    IF v_appeal.case_id IS NOT NULL THEN
        INSERT INTO moderation_case_events (case_id, kind, actor_id, actor_role, detail, note)
        SELECT v_appeal.case_id, 'note', v_actor, u.user_role::text,
               jsonb_build_object('event', 'appeal_' || p_outcome,
                                  'appeal_id', p_appeal, 'reversed', v_reversed),
               p_note
          FROM users u WHERE u.user_id = v_actor;
    END IF;

    -- Tell the member the outcome. Not appealable again at this tier.
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
END $$;

REVOKE ALL ON FUNCTION public.admin_decide_appeal(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_decide_appeal(UUID, TEXT, TEXT) TO authenticated;

-- =========================================================================
-- 5) The queue has to show what is being appealed
-- =========================================================================
-- A row with an empty decision and no date reads as a broken record rather
-- than an account suspension, and a moderator cannot review what the console
-- does not describe.

DROP FUNCTION IF EXISTS public.admin_appeal_queue(TEXT, INT);

CREATE FUNCTION public.admin_appeal_queue(
    p_status TEXT DEFAULT 'open',
    p_limit  INT  DEFAULT 100
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
    created_at         TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

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
           a.created_at
      FROM moderation_appeals a
      JOIN users ap ON ap.user_id = a.appellant_id
      LEFT JOIN moderation_cases c ON c.case_id = a.case_id
      LEFT JOIN notifications n ON n.notification_id = a.enforcement_notification_id
      LEFT JOIN verification_requests r ON r.request_id = a.verification_request_id
      LEFT JOIN users v_decider
             ON v_decider.user_id = COALESCE(c.decided_by, r.reviewed_by,
                                             a.original_decider_id)
     WHERE (p_status IS NULL OR a.status = p_status)
     ORDER BY a.created_at
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
END $$;

REVOKE ALL ON FUNCTION public.admin_appeal_queue(TEXT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_appeal_queue(TEXT, INT) TO authenticated;

-- =========================================================================
-- 6) The enforcement paths pass their audit reference through
-- =========================================================================
-- Without this the notice has no decision_ref, submit_account_appeal cannot
-- resolve who decided, and the independence check falls back to passing for
-- everyone — which is exactly the hole being closed.

CREATE OR REPLACE FUNCTION public.admin_set_user_status(
    p_target UUID,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL,
    p_notify BOOLEAN DEFAULT true
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before JSONB; v_label TEXT; v_after JSONB; v_audit UUID;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    IF p_status NOT IN ('active','suspended','restricted') THEN
        -- 'banned' and 'shadow_banned' were accepted here and rejected by
        -- users_account_status_check every time, so both were dead paths the
        -- console offered. A permanent ban is 'suspended' with
        -- suspended_until NULL; shadow restriction is admin_set_shadow_ban.
        RAISE EXCEPTION
          'invalid status %; permitted: active, suspended, restricted (a permanent ban is suspended with no end date; shadow restriction is admin_set_shadow_ban)',
          p_status;
    END IF;
    SELECT to_jsonb(u), '@' || u.anonymous_pseudonym INTO v_before, v_label
      FROM users u WHERE u.user_id = p_target;
    IF v_before IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    UPDATE users SET account_status = p_status, updated_at = now()
     WHERE user_id = p_target;

    SELECT to_jsonb(u) INTO v_after FROM users u WHERE u.user_id = p_target;

    v_audit := admin_log(
        'user.set_status', 'user', p_target, v_label,
        jsonb_build_object('account_status', v_before->>'account_status'),
        jsonb_build_object('account_status', v_after->>'account_status'),
        p_reason, '{}'::jsonb
    );

    IF p_status IN ('suspended') THEN
        DELETE FROM auth.sessions WHERE user_id = p_target;
    END IF;

    IF p_notify THEN
        PERFORM private.notify_enforcement(
            p_target,
            CASE WHEN p_status = 'active' THEN 'account_reinstated'
                 ELSE 'account_' || p_status END,
            NULL, NULL, p_reason,
            p_status <> 'active',
            v_audit
        );
    END IF;
END $$;

REVOKE ALL ON FUNCTION public.admin_set_user_status(UUID,TEXT,TEXT,BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_user_status(UUID,TEXT,TEXT,BOOLEAN) TO authenticated;

-- The suspension ladder is the other way an account is suspended, and the more
-- common one. Same change: capture the audit id and pass it through.

CREATE OR REPLACE FUNCTION public.admin_suspend_user_ladder(
    p_target UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_count INT; v_label TEXT; v_duration INTERVAL;
    v_until TIMESTAMPTZ; v_tier TEXT; v_before JSONB; v_audit UUID;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT suspension_count, '@' || anonymous_pseudonym, to_jsonb(u)
      INTO v_count, v_label, v_before
      FROM users u WHERE u.user_id = p_target;
    IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    v_duration := CASE v_count WHEN 0 THEN interval '24 hours'
                               WHEN 1 THEN interval '7 days'
                               WHEN 2 THEN interval '30 days'
                               ELSE NULL END;
    v_until := CASE WHEN v_duration IS NULL THEN NULL ELSE now() + v_duration END;
    v_tier  := CASE v_count WHEN 0 THEN '24h' WHEN 1 THEN '7d'
                            WHEN 2 THEN '30d' ELSE 'permanent' END;

    UPDATE users
       SET account_status = 'suspended', suspended_until = v_until,
           suspension_count = suspension_count + 1, updated_at = now()
     WHERE user_id = p_target;

    v_audit := admin_log(
        'user.suspend_ladder', 'user', p_target, v_label,
        jsonb_build_object('account_status', v_before->>'account_status',
                           'suspension_count', v_count),
        jsonb_build_object('account_status', 'suspended',
                           'suspension_count', v_count + 1,
                           'suspended_until', v_until, 'tier', v_tier),
        p_reason, jsonb_build_object('tier', v_tier)
    );

    DELETE FROM auth.sessions WHERE user_id = p_target;

    -- The tier is the member's most useful fact: whether this ends, and when.
    PERFORM private.notify_enforcement(
        p_target, 'account_suspended', NULL, v_tier, p_reason, true, v_audit);

    RETURN jsonb_build_object('tier', v_tier, 'suspended_until', v_until,
                              'suspension_count', v_count + 1);
END $$;

REVOKE ALL ON FUNCTION public.admin_suspend_user_ladder(UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_suspend_user_ladder(UUID,TEXT) TO authenticated;

-- =========================================================================
-- 7) A refused verification tells the applicant again
-- =========================================================================
-- 20261007090000 added a notice to admin_review_verification. 20261014090000
-- rewrote the function for the new workflow — super_admin only, the override
-- flag, the badge award, the verification event log — and did not carry the
-- notice across. It has been gone since. A refused applicant is told nothing
-- and finds out by opening the verification screen, if they think to.
--
-- The body below is the live one, unchanged, with the notice restored and the
-- request id travelling with it. Rewriting it from the older migration would
-- have silently reverted the workflow this project shipped a week ago.

CREATE OR REPLACE FUNCTION public.admin_review_verification(
    p_request UUID,
    p_approve BOOLEAN,
    p_reason  TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public', 'pg_temp' AS $$
DECLARE v_user UUID; v_status TEXT; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can review verification';
    END IF;

    SELECT user_id, status INTO v_user, v_status
      FROM verification_requests WHERE request_id = p_request;
    IF v_user IS NULL THEN RAISE EXCEPTION 'request not found'; END IF;
    IF v_status NOT IN ('pending', 'under_review', 'more_info') THEN
        RAISE EXCEPTION 'request already reviewed';
    END IF;

    -- Rejecting is allowed with no reason; the applicant is told a decision
    -- was made either way. Approving needs none.
    SELECT '@' || anonymous_pseudonym INTO v_label FROM users WHERE user_id = v_user;

    UPDATE verification_requests
       SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
           reviewed_by = auth.uid(), reviewed_at = now(),
           review_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''),
           updated_at = now()
     WHERE request_id = p_request;

    IF p_approve THEN
        UPDATE users
           SET is_verified = true, verification_override = 'manual_on',
               updated_at = now()
         WHERE user_id = v_user;
        BEGIN PERFORM award(v_user, 'verified'); EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    PERFORM private.log_verification_event(
        p_request, v_user,
        CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
        NULLIF(btrim(COALESCE(p_reason, '')), ''));

    PERFORM admin_log(
        CASE WHEN p_approve THEN 'verification.approve' ELSE 'verification.deny' END,
        'user', v_user, v_label, NULL,
        jsonb_build_object('request_id', p_request), p_reason, '{}'::jsonb);

    -- Restored, with the request id, so a refusal is both told and appealable.
    PERFORM private.notify_enforcement(
        v_user,
        CASE WHEN p_approve THEN 'verification_approved' ELSE 'verification_denied' END,
        NULL, NULL, NULLIF(btrim(COALESCE(p_reason, '')), ''),
        NOT p_approve,
        NULL,
        p_request
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_review_verification(UUID,BOOLEAN,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_review_verification(UUID,BOOLEAN,TEXT) TO authenticated;

SELECT public.record_migration(
  '20261022090000', 'account_and_verification_appeals'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
