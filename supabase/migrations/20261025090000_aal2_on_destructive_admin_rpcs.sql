-- A stolen password is no longer enough to suspend an account.
--
-- 20261003090000 introduced private.require_aal2() and applied it to five
-- functions: role changes, account deletion, password-reset authorisation, and
-- the two CSAM paths. Everything else kept a single gate — is_staff(auth.uid())
-- — which a password alone satisfies.
--
-- The console requires MFA, but the console is not the boundary. Its check
-- lives in proxy.ts, and a direct PostgREST call never passes through it. So
-- anyone holding a staff password could suspend accounts, decide moderation
-- cases and search every member on the platform, from curl, with no second
-- factor anywhere in the path.
--
-- That was not theoretical. The only super_admin on this project was a seeded
-- test account whose password is committed to the repository. The password has
-- been rotated; this is the half that makes the next leak survivable.
--
-- The eight below are the ones where a password alone was enough to do
-- something irreversible to a member, or to read across all of them:
--
--   admin_set_user_status         suspend, restrict, reinstate
--   admin_suspend_user_ladder     the tiered path to the same thing
--   admin_lift_suspension         the reverse, and no less consequential
--   admin_set_shadow_ban          restriction the member cannot detect
--   admin_decide_case             enacts removals, suspensions and bans
--   admin_decide_appeal           overturns or upholds, and reinstates
--   admin_global_search           reads across every member on the platform
--   admin_read_case_sensitive_evidence   the sibling of a CSAM read that
--                                        already required a step-up
--
-- Chosen by what a leaked password buys, not by a blanket sweep: 61 admin
-- functions lacked the check, and most are dashboards whose worst case is a
-- disclosed count. Adding it everywhere would also have broken the callers
-- that have no AAL at all — but there are none here. Every one of these eight
-- is called only by the console; none appears in the Flutter client, and none
-- of the 16 cron jobs invokes one. Checked before writing this, because
-- require_aal2 raises when the claim is absent, and a cron job holding no JWT
-- would fail exactly as a stolen password does.
--
-- Two call each other: admin_decide_case calls admin_set_user_status, and
-- admin_decide_appeal calls admin_lift_suspension. Nested calls run under the
-- same JWT claims, so the inner check sees the same aal and passes.
--
-- Bodies are the live definitions with one line inserted after the staff gate,
-- not retyped. Order matters: a non-staff caller still gets 'forbidden' rather
-- than being told which control stopped them.

BEGIN;

-- ------------------------------------------------------------------------
-- admin_decide_appeal
-- ------------------------------------------------------------------------

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
END $function$;

-- ------------------------------------------------------------------------
-- admin_decide_case
-- ------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_decide_case(p_case uuid, p_decision text, p_policy_code text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_before moderation_cases;
    v_actor UUID := auth.uid();
    v_enacted JSONB := '{}'::jsonb;
    v_requester UUID;
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    PERFORM private.require_aal2();

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
END $function$;

-- ------------------------------------------------------------------------
-- admin_global_search
-- ------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_global_search(p_query text, p_limit integer DEFAULT 8)
 RETURNS TABLE(kind text, id uuid, title text, subtitle text, href text, occurred_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_actor UUID := auth.uid();
    v_role  TEXT;
    v_q     TEXT := btrim(COALESCE(p_query, ''));
    v_uuid  UUID;
    v_cap   INT  := LEAST(GREATEST(COALESCE(p_limit, 8), 1), 25);
BEGIN
    -- Patched by 20261018090000: the lookup itself now requires an active
    -- account, so a suspended staff member lands in the v_role IS NULL branch
    -- below and is refused. Done here rather than at the IF, because v_role is
    -- reused further down to scope which results this role may see.
    SELECT user_role::text INTO v_role FROM users
     WHERE user_id = v_actor
       AND COALESCE(account_status, 'active') = 'active'
       AND deactivated_at IS NULL;
    IF v_role IS NULL OR v_role NOT IN
       ('super_admin','admin','moderator','support') THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    PERFORM private.require_aal2();

    IF length(v_q) < 4 THEN
        RAISE EXCEPTION 'search needs at least 4 characters';
    END IF;

    -- An exact id, or nothing. No prefix matching on ids.
    BEGIN
        v_uuid := v_q::uuid;
    EXCEPTION WHEN others THEN
        v_uuid := NULL;
    END;

    PERFORM admin_log(
        'search.global', NULL, NULL, left(v_q, 120),
        NULL, NULL, NULL,
        jsonb_build_object('by_id', v_uuid IS NOT NULL)
    );

    RETURN QUERY
    WITH
    -- One CTE per kind. A per-branch LIMIT is the point — it caps each source
    -- independently so one noisy kind cannot crowd out the others, and it
    -- cannot be expressed inline in a UNION ALL without parenthesising every
    -- branch.
    m_user AS (
        SELECT 'user'::text AS kind, u.user_id AS id,
               ('@' || u.anonymous_pseudonym)::text AS title,
               (u.user_role::text || ' · ' || u.account_status::text)::text AS subtitle,
               ('/users/' || u.user_id::text)::text AS href,
               u.created_at AS occurred_at
          FROM users u
         WHERE (v_uuid IS NOT NULL AND u.user_id = v_uuid)
            OR (v_uuid IS NULL AND u.anonymous_pseudonym ILIKE v_q || '%')
         ORDER BY u.created_at DESC
         LIMIT v_cap
    ),
    m_post AS (
        SELECT 'post'::text, p.post_id,
               left(p.content, 120)::text,
               ('post · ' || COALESCE(pu.anonymous_pseudonym, 'unknown author')
                 || CASE WHEN p.deleted_at IS NOT NULL THEN ' · removed' ELSE '' END)::text,
               '/moderation?tab=cases'::text,
               p.created_at
          FROM posts p
          LEFT JOIN users pu ON pu.user_id = p.author_id
         WHERE (v_uuid IS NOT NULL AND p.post_id = v_uuid)
            OR (v_uuid IS NULL AND p.content ILIKE '%' || v_q || '%')
         ORDER BY p.created_at DESC
         LIMIT v_cap
    ),
    m_tribe AS (
        SELECT 'tribe'::text, t.tribe_id, t.name::text,
               ('tribe · ' || COALESCE(t.slug, ''))::text,
               ('/tribes/' || t.tribe_id::text)::text,
               t.created_at
          FROM tribes t
         WHERE (v_uuid IS NOT NULL AND t.tribe_id = v_uuid)
            OR (v_uuid IS NULL AND (t.name ILIKE '%' || v_q || '%'
                                    OR t.slug ILIKE '%' || v_q || '%'))
         ORDER BY t.created_at DESC
         LIMIT v_cap
    ),
    -- Cases, reports and appeals are id-only: there is no text on them worth
    -- matching, and letting text hit them would turn the box into a way to
    -- trawl the moderation backlog.
    m_case AS (
        SELECT 'case'::text, c.case_id,
               (c.target_type || ' · ' || c.severity || ' · ' || c.status)::text,
               ('case · ' || COALESCE('@' || su.anonymous_pseudonym, 'no subject'))::text,
               '/moderation?tab=cases'::text,
               c.opened_at
          FROM moderation_cases c
          LEFT JOIN users su ON su.user_id = c.subject_id
         WHERE v_uuid IS NOT NULL
           AND (c.case_id = v_uuid OR c.target_id = v_uuid OR c.subject_id = v_uuid)
         ORDER BY c.opened_at DESC
         LIMIT v_cap
    ),
    m_report AS (
        SELECT 'report'::text, r.report_id,
               (r.reason || CASE WHEN r.is_resolved THEN ' · resolved' ELSE ' · open' END)::text,
               'report'::text, '/moderation'::text, r.created_at
          FROM reports r
         WHERE v_uuid IS NOT NULL AND r.report_id = v_uuid
         LIMIT v_cap
    ),
    m_appeal AS (
        SELECT 'appeal'::text, a.appeal_id, ('appeal · ' || a.status)::text,
               ('@' || COALESCE(au.anonymous_pseudonym, 'unknown'))::text,
               '/appeals'::text, a.created_at
          FROM moderation_appeals a
          LEFT JOIN users au ON au.user_id = a.appellant_id
         WHERE v_uuid IS NOT NULL AND a.appeal_id = v_uuid
         LIMIT v_cap
    ),
    -- super_admin only, and gated inside the query rather than filtered after,
    -- so no other role can learn that an incident exists for a given id.
    m_csam AS (
        SELECT 'csam_incident'::text, ci.incident_id,
               ('CSAM incident · ' || ci.status)::text,
               'restricted'::text, '/csam'::text, ci.detected_at
          FROM csam_incidents ci
         WHERE v_role = 'super_admin'
           AND v_uuid IS NOT NULL
           AND (ci.incident_id = v_uuid OR ci.content_ref = v_uuid OR ci.author_id = v_uuid)
         LIMIT v_cap
    ),
    found AS (
        SELECT * FROM m_user   UNION ALL SELECT * FROM m_case
        UNION ALL SELECT * FROM m_appeal UNION ALL SELECT * FROM m_report
        UNION ALL SELECT * FROM m_csam   UNION ALL SELECT * FROM m_tribe
        UNION ALL SELECT * FROM m_post
    )
    SELECT f.kind, f.id, f.title, f.subtitle, f.href, f.occurred_at
      FROM found f
     ORDER BY
       CASE f.kind WHEN 'user' THEN 0 WHEN 'case' THEN 1 WHEN 'appeal' THEN 2
                   WHEN 'report' THEN 3 WHEN 'csam_incident' THEN 4
                   WHEN 'tribe' THEN 5 ELSE 6 END,
       f.occurred_at DESC
     LIMIT v_cap * 3;
END $function$;

-- ------------------------------------------------------------------------
-- admin_lift_suspension
-- ------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_lift_suspension(p_target uuid, p_reason text DEFAULT NULL::text, p_notify boolean DEFAULT true)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    PERFORM private.require_aal2();
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
END $function$;

-- ------------------------------------------------------------------------
-- admin_read_case_sensitive_evidence
-- ------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_read_case_sensitive_evidence(p_case uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_case moderation_cases; v_actor UUID := auth.uid();
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    PERFORM private.require_aal2();

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
END $function$;

-- ------------------------------------------------------------------------
-- admin_set_shadow_ban
-- ------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_set_shadow_ban(p_user uuid, p_banned boolean, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_label TEXT;
BEGIN
  IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
    PERFORM private.require_aal2();
  SELECT '@' || anonymous_pseudonym INTO v_label FROM users WHERE user_id = p_user;
  IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
  UPDATE users SET shadow_banned = p_banned WHERE user_id = p_user;
  PERFORM admin_log(
    CASE WHEN p_banned THEN 'user.shadow_ban' ELSE 'user.shadow_unban' END,
    'user', p_user, v_label,
    NULL, jsonb_build_object('shadow_banned', p_banned),
    p_reason, '{}'::jsonb);
END;
$function$;

-- ------------------------------------------------------------------------
-- admin_set_user_status
-- ------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_set_user_status(p_target uuid, p_status text, p_reason text DEFAULT NULL::text, p_notify boolean DEFAULT true)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_before JSONB; v_label TEXT; v_after JSONB; v_audit UUID;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    PERFORM private.require_aal2();
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
END $function$;

-- ------------------------------------------------------------------------
-- admin_suspend_user_ladder
-- ------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_suspend_user_ladder(p_target uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_count INT; v_label TEXT; v_duration INTERVAL;
    v_until TIMESTAMPTZ; v_tier TEXT; v_before JSONB; v_audit UUID;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    PERFORM private.require_aal2();

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
END $function$;

SELECT public.record_migration(
  '20261025090000', 'aal2_on_destructive_admin_rpcs'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
