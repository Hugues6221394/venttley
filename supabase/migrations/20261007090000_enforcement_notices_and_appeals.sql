-- Member appeals and independent second review.
--
-- The README lists appeals as P0 and "member-visible enforcement notices" as
-- P1. That ordering cannot hold: not one enforcement path tells the member
-- anything. admin_set_user_status, admin_suspend_user_ladder,
-- admin_set_shadow_ban, admin_set_post_deleted, admin_decide_case and
-- admin_review_verification between them write zero rows a member can see. A
-- member is suspended, has content removed, or is refused verification, and
-- is never told — so an appeals system layered on top of that would only ever
-- be used by someone who guessed. You cannot appeal a decision you were not
-- told about. The notice is therefore part of this migration, not a later one.
--
-- notifications.kind has reserved 'moderation_action' since 0001_init_schema
-- and nothing has ever written it. This uses that rather than inventing a
-- second channel.
--
-- Two things the notice deliberately does NOT do:
--
--   * It never names or hints at the reporter. Reporter privacy already cost
--     this project a bug (f71d9c2, "a Keeper could see who reported them");
--     the payload carries the policy and the decision, never who raised it.
--   * Shadow restriction sends nothing. Its entire mechanism is that the
--     affected member cannot tell it happened, so a notice would defeat it —
--     the same reason it is excluded from session revocation. That means a
--     shadow restriction is also unappealable, which is a real and deliberate
--     asymmetry, and one worth revisiting as policy rather than hiding here.

-- =========================================================================
-- 1) Telling the member
-- =========================================================================

CREATE OR REPLACE FUNCTION private.notify_enforcement(
    p_user     UUID,
    p_action   TEXT,
    p_case     UUID DEFAULT NULL,
    p_policy   TEXT DEFAULT NULL,
    p_reason   TEXT DEFAULT NULL,
    p_appealable BOOLEAN DEFAULT true
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
            'decided_at', now()
        ))
    );
END $$;

REVOKE ALL ON FUNCTION private.notify_enforcement(UUID, TEXT, UUID, TEXT, TEXT, BOOLEAN)
    FROM PUBLIC, anon, authenticated;

-- =========================================================================
-- 2) Appeals
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.moderation_appeals (
    appeal_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Exactly one subject, in the shape reports_one_target already uses.
    case_id                 UUID REFERENCES public.moderation_cases(case_id) ON DELETE CASCADE,
    verification_request_id  UUID REFERENCES public.verification_requests(request_id) ON DELETE CASCADE,

    appellant_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    statement    TEXT NOT NULL CHECK (length(btrim(statement)) BETWEEN 1 AND 2000),

    status TEXT NOT NULL DEFAULT 'open'
           CHECK (status IN ('open', 'upheld', 'overturned', 'withdrawn')),

    -- Independence is the whole point: this must never equal the person who
    -- took the original decision. Enforced in admin_decide_appeal.
    reviewer_id UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    reviewed_at TIMESTAMPTZ,
    review_note TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT appeals_one_subject CHECK (
        (CASE WHEN case_id IS NOT NULL THEN 1 ELSE 0 END +
         CASE WHEN verification_request_id IS NOT NULL THEN 1 ELSE 0 END) = 1
    )
);

-- One open appeal per decision. This index only prevents two being open
-- simultaneously; "a decided appeal is final" is a separate rule and is
-- enforced explicitly in submit_appeal, because a partial unique index on
-- status='open' cannot express it — an upheld appeal leaves the slot free.
CREATE UNIQUE INDEX IF NOT EXISTS appeals_one_open_per_case
    ON public.moderation_appeals (case_id)
    WHERE case_id IS NOT NULL AND status = 'open';
CREATE UNIQUE INDEX IF NOT EXISTS appeals_one_open_per_verification
    ON public.moderation_appeals (verification_request_id)
    WHERE verification_request_id IS NOT NULL AND status = 'open';

CREATE INDEX IF NOT EXISTS appeals_queue_idx
    ON public.moderation_appeals (status, created_at)
    WHERE status = 'open';
CREATE INDEX IF NOT EXISTS appeals_appellant_idx
    ON public.moderation_appeals (appellant_id, created_at DESC);

ALTER TABLE public.moderation_appeals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.moderation_appeals FROM anon, authenticated;

-- A member may read their own appeals — otherwise "appeal status" is another
-- thing they cannot see. Staff read through the RPC.
DROP POLICY IF EXISTS "appeals own read" ON public.moderation_appeals;
CREATE POLICY "appeals own read" ON public.moderation_appeals FOR SELECT
    USING (appellant_id = auth.uid());
GRANT SELECT ON public.moderation_appeals TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =========================================================================
-- 3) Filing an appeal — the member's side
-- =========================================================================

CREATE OR REPLACE FUNCTION public.submit_appeal(
    p_case      UUID,
    p_statement TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_case moderation_cases; v_uid UUID := auth.uid(); v_id UUID;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT * INTO v_case FROM moderation_cases WHERE case_id = p_case;
    IF v_case.case_id IS NULL THEN RAISE EXCEPTION 'case not found'; END IF;

    -- Only the person the decision was about. Not "any member who knows an
    -- id": a case id in someone else's hands must not become a way to read or
    -- influence a decision about a third party.
    IF v_case.subject_id IS DISTINCT FROM v_uid THEN
        RAISE EXCEPTION 'forbidden: only the subject of a decision may appeal it';
    END IF;

    IF v_case.decision IS NULL THEN
        RAISE EXCEPTION 'this case has no decision to appeal yet';
    END IF;
    IF v_case.decision = 'no_action' THEN
        RAISE EXCEPTION 'there is nothing to appeal: no action was taken';
    END IF;
    -- Consistent with sending no notice for it: a shadow restriction the
    -- member cannot be told about cannot be one they are invited to contest.
    IF v_case.decision = 'user_shadow_restricted' THEN
        RAISE EXCEPTION 'this decision is not appealable';
    END IF;

    -- A window, so a decision becomes final at some point. 30 days from the
    -- decision, not from the case opening.
    IF v_case.decided_at < now() - interval '30 days' THEN
        RAISE EXCEPTION 'the 30-day window to appeal this decision has passed';
    END IF;

    -- One bite at this tier. Withdrawing does not spend it; being heard does.
    -- Without this a member could re-appeal an upheld decision indefinitely,
    -- and the unique index above would not stop them: it keys on
    -- status='open', which an upheld appeal vacates.
    IF EXISTS (
        SELECT 1 FROM moderation_appeals a
         WHERE a.case_id = p_case
           AND a.appellant_id = v_uid
           AND a.status IN ('upheld', 'overturned')
    ) THEN
        RAISE EXCEPTION
          'this decision has already been through appeal; that outcome is final at this tier';
    END IF;

    INSERT INTO moderation_appeals (case_id, appellant_id, statement)
    VALUES (p_case, v_uid, p_statement)
    RETURNING appeal_id INTO v_id;

    -- The case history is what the reviewing moderator reads, so the appeal
    -- has to appear in it rather than only in a separate table.
    INSERT INTO moderation_case_events (case_id, kind, actor_id, detail, note)
    VALUES (p_case, 'note', v_uid,
            jsonb_build_object('event', 'appeal_filed', 'appeal_id', v_id),
            left(p_statement, 500));

    RETURN v_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'you already have an appeal open on this decision';
END $$;

REVOKE ALL ON FUNCTION public.submit_appeal(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_appeal(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.withdraw_appeal(p_appeal UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid UUID := auth.uid();
BEGIN
    UPDATE moderation_appeals
       SET status = 'withdrawn'
     WHERE appeal_id = p_appeal
       AND appellant_id = v_uid
       AND status = 'open';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no open appeal of yours with that id';
    END IF;
END $$;

REVOKE ALL ON FUNCTION public.withdraw_appeal(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.withdraw_appeal(UUID) TO authenticated;

-- =========================================================================
-- 4) Deciding an appeal — independently
-- =========================================================================
-- The integrity property this whole feature rests on: the person who reviews
-- an appeal must not be the person whose decision is being appealed. Without
-- that, an appeal is a request to someone to disagree with themselves.

CREATE OR REPLACE FUNCTION public.admin_decide_appeal(
    p_appeal  UUID,
    p_outcome TEXT,
    p_note    TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_appeal moderation_appeals;
    v_case   moderation_cases;
    v_actor  UUID := auth.uid();
    v_reversed JSONB := '{}'::jsonb;
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

    -- Independence.
    IF v_case.decided_by IS NOT NULL AND v_case.decided_by = v_actor THEN
        RAISE EXCEPTION
          'forbidden: you took the decision being appealed; an appeal must be reviewed by someone else';
    END IF;
    -- And an appellant cannot review their own appeal, which is reachable
    -- because staff are members too.
    IF v_appeal.appellant_id = v_actor THEN
        RAISE EXCEPTION 'forbidden: you cannot review your own appeal';
    END IF;

    -- Overturning has to undo the thing. An upheld-then-nothing-happens
    -- appeal is the same defect as a decision that records without enacting:
    -- the record says the member won and their content is still gone.
    IF p_outcome = 'overturned' AND v_case.case_id IS NOT NULL THEN
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
            -- Reuse the existing lift path rather than writing status here, so
            -- the reinstatement is audited like any other status change.
            PERFORM admin_lift_suspension(v_case.subject_id,
                     'appeal ' || p_appeal::text || ' overturned');
            v_reversed := jsonb_build_object('suspension_lifted', true);
        END IF;
    END IF;

    UPDATE moderation_appeals
       SET status = p_outcome, reviewer_id = v_actor,
           reviewed_at = now(), review_note = p_note
     WHERE appeal_id = p_appeal;

    INSERT INTO moderation_case_events (case_id, kind, actor_id, actor_role, detail, note)
    SELECT v_appeal.case_id, 'note', v_actor, u.user_role::text,
           jsonb_build_object('event', 'appeal_' || p_outcome,
                              'appeal_id', p_appeal, 'reversed', v_reversed),
           p_note
      FROM users u WHERE u.user_id = v_actor;

    -- Tell the member the outcome. Not appealable again at this tier.
    PERFORM private.notify_enforcement(
        v_appeal.appellant_id,
        'appeal_' || p_outcome,
        v_appeal.case_id,
        v_case.policy_code,
        p_note,
        false
    );

    PERFORM admin_log(
        'appeal.' || p_outcome, 'moderation_appeal', p_appeal, v_case.target_type,
        jsonb_build_object('original_decision', v_case.decision,
                           'original_decider', v_case.decided_by),
        jsonb_build_object('outcome', p_outcome, 'reversed', v_reversed),
        p_note, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_decide_appeal(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_decide_appeal(UUID, TEXT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =========================================================================
-- 5) The appeal queue
-- =========================================================================

CREATE OR REPLACE FUNCTION public.admin_appeal_queue(
    p_status TEXT DEFAULT 'open',
    p_limit  INT  DEFAULT 100
) RETURNS TABLE (
    appeal_id          UUID,
    case_id            UUID,
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
    SELECT a.appeal_id, a.case_id, a.appellant_id, ap.anonymous_pseudonym::text,
           a.statement, a.status, c.target_type, c.decision, c.policy_code,
           c.decision_note, c.decided_by, du.anonymous_pseudonym::text,
           c.decided_at,
           -- Surfaced so the console can hide the controls rather than let a
           -- moderator submit a review the RPC will refuse.
           (c.decided_by IS DISTINCT FROM auth.uid()
            AND a.appellant_id IS DISTINCT FROM auth.uid()) AS reviewable_by_me,
           a.created_at
      FROM moderation_appeals a
      JOIN users ap ON ap.user_id = a.appellant_id
      LEFT JOIN moderation_cases c ON c.case_id = a.case_id
      LEFT JOIN users du ON du.user_id = c.decided_by
     WHERE (p_status IS NULL OR a.status = p_status)
     ORDER BY a.created_at
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
END $$;

REVOKE ALL ON FUNCTION public.admin_appeal_queue(TEXT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_appeal_queue(TEXT, INT) TO authenticated;

-- =========================================================================
-- 6) Enforcement paths now tell the member
-- =========================================================================
-- admin_set_user_status gains p_notify so admin_decide_case can suppress it
-- and send one richer notice instead of the member receiving two for one
-- decision. Direct calls keep notifying by default.

CREATE OR REPLACE FUNCTION public.admin_set_user_status(
    p_target UUID,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL,
    p_notify BOOLEAN DEFAULT true
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before JSONB; v_label TEXT; v_after JSONB;
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

    PERFORM admin_log(
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
            p_status <> 'active'
        );
    END IF;
END $$;

REVOKE ALL ON FUNCTION public.admin_set_user_status(UUID,TEXT,TEXT,BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_user_status(UUID,TEXT,TEXT,BOOLEAN) TO authenticated;
DROP FUNCTION IF EXISTS public.admin_set_user_status(UUID,TEXT,TEXT);

NOTIFY pgrst, 'reload schema';

-- admin_lift_suspension also gains p_notify, for the same reason: the appeal
-- path calls it and then sends its own outcome notice, and the member should
-- not receive two messages about one reinstatement.
CREATE OR REPLACE FUNCTION public.admin_lift_suspension(
    p_target UUID,
    p_reason TEXT DEFAULT NULL,
    p_notify BOOLEAN DEFAULT true
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    SELECT '@' || anonymous_pseudonym INTO v_label FROM users WHERE user_id = p_target;
    IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    UPDATE users
       SET account_status = 'active', suspended_until = NULL, updated_at = now()
     WHERE user_id = p_target;

    PERFORM admin_log('user.lift_suspension', 'user', p_target, v_label,
                      NULL, jsonb_build_object('account_status', 'active'),
                      p_reason, '{}'::jsonb);

    IF p_notify THEN
        PERFORM private.notify_enforcement(
            p_target, 'account_reinstated', NULL, NULL, p_reason, false);
    END IF;
END $$;

REVOKE ALL ON FUNCTION public.admin_lift_suspension(UUID,TEXT,BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_lift_suspension(UUID,TEXT,BOOLEAN) TO authenticated;
DROP FUNCTION IF EXISTS public.admin_lift_suspension(UUID,TEXT);

-- The ladder is a second path to suspension and needs the same notice.
CREATE OR REPLACE FUNCTION public.admin_suspend_user_ladder(
    p_target UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_count INT; v_label TEXT; v_duration INTERVAL;
    v_until TIMESTAMPTZ; v_tier TEXT; v_before JSONB;
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

    PERFORM admin_log(
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
        p_target, 'account_suspended', NULL, v_tier, p_reason, true);

    RETURN jsonb_build_object('tier', v_tier, 'suspended_until', v_until,
                              'suspension_count', v_count + 1);
END $$;

-- Verification decisions are appealable per the README, so the applicant has
-- to be told the outcome.
CREATE OR REPLACE FUNCTION public.admin_review_verification(
    p_request UUID,
    p_approve BOOLEAN,
    p_reason  TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user UUID; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT r.user_id, '@' || u.anonymous_pseudonym INTO v_user, v_label
      FROM verification_requests r JOIN users u ON u.user_id = r.user_id
     WHERE r.request_id = p_request AND r.status = 'pending';
    IF v_user IS NULL THEN RAISE EXCEPTION 'no pending request with that id'; END IF;

    UPDATE verification_requests
       SET status = CASE WHEN p_approve THEN 'approved' ELSE 'denied' END,
           reviewed_by = auth.uid(), reviewed_at = now(), review_reason = p_reason
     WHERE request_id = p_request;

    IF p_approve THEN
        UPDATE users SET is_verified = true, updated_at = now() WHERE user_id = v_user;
    END IF;

    PERFORM admin_log(
        CASE WHEN p_approve THEN 'verification.approve' ELSE 'verification.deny' END,
        'verification_request', p_request, v_label,
        NULL, jsonb_build_object('approved', p_approve), p_reason, '{}'::jsonb
    );

    PERFORM private.notify_enforcement(
        v_user,
        CASE WHEN p_approve THEN 'verification_approved' ELSE 'verification_denied' END,
        NULL, NULL, p_reason,
        NOT p_approve
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_review_verification(UUID,BOOLEAN,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_review_verification(UUID,BOOLEAN,TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =========================================================================
-- 7) admin_decide_case: one notice, and second review that is independent
-- =========================================================================
-- Two changes. It suppresses the notice from admin_set_user_status and sends
-- its own, which carries the case id and policy code the member needs in
-- order to appeal — the status RPC has neither.
--
-- And it enforces independence on second review. admin_set_case_status could
-- already move a case to 'awaiting_second_review', but nothing stopped the
-- moderator who asked for a second opinion from providing it themselves,
-- which makes the status a formality. The requester is read out of the case
-- history rather than stored again.

CREATE OR REPLACE FUNCTION public.admin_decide_case(
    p_case        UUID,
    p_decision    TEXT,
    p_policy_code TEXT DEFAULT NULL,
    p_note        TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_before moderation_cases;
    v_actor UUID := auth.uid();
    v_enacted JSONB := '{}'::jsonb;
    v_requester UUID;
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT * INTO v_before FROM moderation_cases WHERE case_id = p_case;
    IF v_before.case_id IS NULL THEN RAISE EXCEPTION 'case not found'; END IF;

    IF p_decision <> 'no_action' AND COALESCE(btrim(p_note), '') = '' THEN
        RAISE EXCEPTION 'a decision that affects a member requires a note';
    END IF;

    IF v_before.status = 'awaiting_second_review' THEN
        SELECT e.actor_id INTO v_requester
          FROM moderation_case_events e
         WHERE e.case_id = p_case
           AND e.kind = 'status_changed'
           AND e.detail->>'to' = 'awaiting_second_review'
         ORDER BY e.created_at DESC LIMIT 1;

        IF v_requester IS NOT NULL AND v_requester = v_actor THEN
            RAISE EXCEPTION
              'forbidden: you asked for a second review on this case; someone else has to give it';
        END IF;
    END IF;

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
            RAISE EXCEPTION
              'content_removed is not implemented for target_type %; use a status decision or escalate',
              v_before.target_type;
        END IF;
        v_enacted := jsonb_build_object('removed', v_before.target_type);

    ELSIF p_decision IN ('user_suspended', 'user_banned', 'user_shadow_restricted') THEN
        IF v_before.subject_id IS NULL THEN
            RAISE EXCEPTION 'this case has no subject to act on';
        END IF;

        IF p_decision = 'user_shadow_restricted' THEN
            PERFORM admin_set_shadow_ban(v_before.subject_id, true, p_note);
            v_enacted := jsonb_build_object('shadow_banned', true);
        ELSE
            -- p_notify => false: this function sends one notice below with the
            -- case id and policy the member needs to appeal.
            PERFORM admin_set_user_status(v_before.subject_id, 'suspended', p_note, false);
            IF p_decision = 'user_banned' THEN
                UPDATE users SET suspended_until = NULL, updated_at = now()
                 WHERE user_id = v_before.subject_id;
                v_enacted := jsonb_build_object('account_status', 'suspended',
                                                'permanent', true);
            ELSE
                v_enacted := jsonb_build_object('account_status', 'suspended');
            END IF;
        END IF;

    ELSIF p_decision = 'user_warned' THEN
        -- Now actually delivered: the notice below is the warning. Before this
        -- migration there was no member-facing channel and the decision
        -- reached nobody but staff.
        v_enacted := jsonb_build_object('warning_delivered', true);
    END IF;

    UPDATE moderation_cases
       SET decision = p_decision, decided_by = v_actor, decided_at = now(),
           decision_note = p_note,
           policy_code = COALESCE(p_policy_code, policy_code),
           status = 'resolved',
           first_action_at = COALESCE(first_action_at, now()),
           updated_at = now()
     WHERE case_id = p_case;

    UPDATE reports
       SET is_resolved = true, resolved_at = now(), resolved_by = v_actor
     WHERE case_id = p_case AND is_resolved = false;

    INSERT INTO moderation_case_events (case_id, kind, actor_id, actor_role, detail, note)
    SELECT p_case, 'decided', v_actor, u.user_role::text,
           jsonb_build_object('decision', p_decision, 'policy_code', p_policy_code,
                              'enacted', v_enacted, 'second_review_of', v_requester),
           p_note
      FROM users u WHERE u.user_id = v_actor;

    -- Tell the member, except where telling them defeats the measure.
    IF v_before.subject_id IS NOT NULL
       AND p_decision NOT IN ('no_action', 'user_shadow_restricted', 'escalated_external') THEN
        PERFORM private.notify_enforcement(
            v_before.subject_id,
            'case_' || p_decision,
            p_case,
            COALESCE(p_policy_code, v_before.policy_code),
            p_note,
            true
        );
    END IF;

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
