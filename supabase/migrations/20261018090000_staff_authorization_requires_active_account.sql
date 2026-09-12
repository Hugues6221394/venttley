-- =========================================================================
-- Suspending a staff account did not take anything away
--
-- Found while building the staff RLS policy matrix the README asks for
-- ("anonymous, normal, suspended staff, each staff role, super admin, and
-- service role"). Writing the "suspended staff" row is what surfaced it:
-- there was nothing to assert, because suspension had no effect on staff
-- authorisation anywhere in the system.
--
--   public.is_staff(p_user, p_roles) checked user_role and nothing else.
--
-- Every privileged path derives authority from that one predicate — 65
-- functions call it — and none of them looked at account_status. Thirteen RLS
-- policies re-implement the same check inline, and none of those looked
-- either. Nor does the console: proxy.ts and the dashboard layout both gate on
-- role alone, and the layout selects only `anonymous_pseudonym, user_role`.
--
-- Demonstrated, not inferred. With devon set to admin/suspended:
--
--   GET /rest/v1/audit_log?select=action,actor_pseudonym  ->  200, rows
--
-- A suspended admin reads the entire privileged audit ledger straight through
-- PostgREST. Their token keeps working, `admin_global_search` keeps returning
-- accounts, and every is_staff-gated RPC keeps answering. Suspension was a
-- label on a row, not a boundary. The only things that actually removed a
-- staff member's power were changing their role or deleting the account —
-- which means the safe, reversible, obvious move an operator would reach for
-- first was the one that did nothing.
--
-- WHAT "ACTIVE" MEANS HERE
--
-- users_account_status_check permits ('active','suspended','restricted'), so
-- only 'active' keeps authority: 'restricted' is a sanction too.
-- deactivated_at is also honoured — an account that has been deactivated
-- should not be moderating.
--
-- account_status is NULLABLE with a DEFAULT of 'active', so NULL means "never
-- set", not "not active". It is COALESCEd to 'active' deliberately: reading
-- NULL as inactive would lock out every staff account whose row predates the
-- column, which is a worse failure than the one being fixed and would present
-- as the console simply being broken for everyone.
--
-- THE THIRTEEN POLICIES NOW CALL is_staff RATHER THAN RESTATING IT
--
-- All thirteen were the same shape —
--   EXISTS (SELECT 1 FROM users u WHERE u.user_id = (SELECT auth.uid())
--           AND <role test>)
-- — differing only in the role list. Thirteen copies of an authorisation rule
-- is thirteen places to forget when the rule changes, which is exactly how
-- this bug survived: is_staff was the place everyone thought the rule lived,
-- and the policies had quietly forked from it. They now delegate, so the next
-- change to what "staff" means lands everywhere at once.
--
-- The call is wrapped in a scalar subselect — (SELECT public.is_staff(...)) —
-- so the planner evaluates it once as an InitPlan instead of per row. Three of
-- these tables (posts, posts_comments, tribes) are read on hot paths, and
-- is_staff carries SET search_path, which makes it non-inlinable; without the
-- wrapper this would be a per-row function call on the feed. That is the same
-- reason the original policies wrote (SELECT auth.uid()) rather than
-- auth.uid().
--
-- Three of the thirteen are dead today: reports, admin_broadcasts and
-- csam_incidents have no SELECT grant to authenticated, so Postgres refuses
-- on the table privilege before the policy is ever consulted. They are fixed
-- anyway. A dead policy that someone later revives with a GRANT should not
-- come back carrying a hole, and csam_incidents is exactly the table where
-- that mistake was found last.
--
-- NOT FIXED HERE, DELIBERATELY
--
-- public.queue_email still checks user_role inline to decide whether the
-- caller may queue mail addressed to someone else. It is a different subsystem
-- with a different blast radius and its own tests, and bundling it into an
-- authorisation change this wide would make both harder to review or revert.
-- Tracked in the README instead.
--
-- The console-side check is also not here — it belongs in TypeScript, and the
-- database is the boundary that matters. Noted in the README as the remaining
-- half.
-- =========================================================================

-- =========================================================================
-- 1) The predicate itself
-- =========================================================================

CREATE OR REPLACE FUNCTION public.is_staff(
    p_user  UUID,
    p_roles TEXT[] DEFAULT ARRAY['super_admin','admin']
) RETURNS BOOLEAN
LANGUAGE sql STABLE
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.users u
         WHERE u.user_id = p_user
           AND u.user_role::text = ANY(p_roles)
           -- Added. A suspended or restricted moderator is still a moderator
           -- by title; they must stop being one in effect.
           AND COALESCE(u.account_status, 'active') = 'active'
           AND u.deactivated_at IS NULL
    );
$$;

COMMENT ON FUNCTION public.is_staff(UUID, TEXT[]) IS
  'True when the user holds one of the given staff roles AND the account is active. Authority follows the account state, not just the title. Every staff authorisation should route through this rather than re-checking user_role.';

-- =========================================================================
-- 2) The thirteen policies
-- =========================================================================

DROP POLICY IF EXISTS "audit admin read" ON public.admin_audit_log;
CREATE POLICY "audit admin read" ON public.admin_audit_log
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()), ARRAY['super_admin'])));

DROP POLICY IF EXISTS "broadcasts admin read" ON public.admin_broadcasts;
CREATE POLICY "broadcasts admin read" ON public.admin_broadcasts
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()), ARRAY['super_admin'])));

DROP POLICY IF EXISTS "events admin read" ON public.analytics_events;
CREATE POLICY "events admin read" ON public.analytics_events
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()), ARRAY['super_admin'])));

DROP POLICY IF EXISTS "csam super_admin read" ON public.csam_incidents;
CREATE POLICY "csam super_admin read" ON public.csam_incidents
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()), ARRAY['super_admin'])));

DROP POLICY IF EXISTS "audit read staff" ON public.audit_log;
CREATE POLICY "audit read staff" ON public.audit_log
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()),
        ARRAY['super_admin','admin','read_only_auditor'])));

DROP POLICY IF EXISTS "broadcasts staff full read" ON public.broadcasts;
CREATE POLICY "broadcasts staff full read" ON public.broadcasts
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()),
        ARRAY['super_admin','admin','moderator','read_only_auditor'])));

DROP POLICY IF EXISTS "reports admin read" ON public.reports;
CREATE POLICY "reports admin read" ON public.reports
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()),
        ARRAY['super_admin','admin','moderator','read_only_auditor'])));

DROP POLICY IF EXISTS "post_likes staff read" ON public.post_likes;
CREATE POLICY "post_likes staff read" ON public.post_likes
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()),
        ARRAY['super_admin','admin','analyst','read_only_auditor'])));

DROP POLICY IF EXISTS "posts staff full read" ON public.posts;
CREATE POLICY "posts staff full read" ON public.posts
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()),
        ARRAY['super_admin','admin','moderator','read_only_auditor'])));

DROP POLICY IF EXISTS "comments staff full read" ON public.posts_comments;
CREATE POLICY "comments staff full read" ON public.posts_comments
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()),
        ARRAY['super_admin','admin','moderator','read_only_auditor'])));

DROP POLICY IF EXISTS "tribes staff full read" ON public.tribes;
CREATE POLICY "tribes staff full read" ON public.tribes
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()),
        ARRAY['super_admin','admin','moderator','read_only_auditor'])));

DROP POLICY IF EXISTS "user_streaks staff read" ON public.user_streaks;
CREATE POLICY "user_streaks staff read" ON public.user_streaks
    FOR SELECT USING ((SELECT public.is_staff((SELECT auth.uid()),
        ARRAY['super_admin','admin','moderator','read_only_auditor'])));

-- Keeps its own-row branch: a member reading their own override is not a
-- staff act and must not start depending on staff status.
DROP POLICY IF EXISTS "flag overrides self read" ON public.feature_flag_overrides;
CREATE POLICY "flag overrides self read" ON public.feature_flag_overrides
    FOR SELECT USING (
        user_id = (SELECT auth.uid())
        OR (SELECT public.is_staff((SELECT auth.uid()), ARRAY['super_admin']))
    );

-- =========================================================================
-- 3) The CSAM functions, which checked user_role inline
--
-- Rewritten to delegate for the same reason as the policies. Bodies are
-- otherwise unchanged.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.admin_open_csam_count()
RETURNS INTEGER
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $$
    SELECT count(*)::int FROM public.csam_incidents
     WHERE status = 'detected'
       AND public.is_staff(auth.uid(), ARRAY['super_admin']);
$$;

CREATE OR REPLACE FUNCTION public.admin_resolve_csam_incident(
    p_incident_id UUID,
    p_status      TEXT,
    p_report_ref  TEXT DEFAULT NULL,
    p_notes       TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_rec RECORD;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    PERFORM private.require_aal2();
    IF p_status NOT IN ('reported','cleared','false_positive') THEN
        RAISE EXCEPTION 'invalid status %', p_status;
    END IF;

    UPDATE public.csam_incidents
       SET status = p_status, report_reference = p_report_ref,
           reviewed_by = auth.uid(), reviewed_at = now(), notes = p_notes
     WHERE incident_id = p_incident_id
     RETURNING * INTO v_rec;
    IF v_rec.incident_id IS NULL THEN RAISE EXCEPTION 'incident not found'; END IF;

    -- Only a confirmed false positive restores the content.
    IF p_status = 'false_positive' THEN
        IF v_rec.kind = 'post' THEN
            UPDATE posts SET media_status = 'clean', deleted_at = NULL
             WHERE post_id = v_rec.content_ref;
        ELSE
            UPDATE whispers SET media_status = 'clean', deleted_at = NULL
             WHERE whisper_id = v_rec.content_ref;
        END IF;
    END IF;

    PERFORM admin_log('csam.resolve', 'csam_incident', p_incident_id, NULL,
                      NULL, jsonb_build_object('status', p_status,
                                               'report_reference', p_report_ref),
                      p_notes, '{}'::jsonb);
END $$;

-- admin_csam_queue and admin_read_csam_evidence, from 20261017090000, checked
-- user_role inline as well. Only their role tests change.

CREATE OR REPLACE FUNCTION public.admin_csam_queue(
    p_status TEXT DEFAULT NULL,
    p_limit  INT  DEFAULT 200
) RETURNS TABLE (
    incident_id       UUID,
    kind              TEXT,
    status            TEXT,
    detected_at       TIMESTAMPTZ,
    reviewed_at       TIMESTAMPTZ,
    reviewer          TEXT,
    report_reference  TEXT,
    notes             TEXT,
    label_count       INT,
    evidence_reads    INT
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_actor UUID := auth.uid(); v_count INT;
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    IF p_status IS NOT NULL
       AND p_status NOT IN ('detected','reported','cleared','false_positive') THEN
        RAISE EXCEPTION 'unknown status %', p_status;
    END IF;

    SELECT count(*) INTO v_count
      FROM csam_incidents i
     WHERE p_status IS NULL OR i.status = p_status;

    PERFORM admin_log(
        'csam.queue_read', 'csam_incident', NULL, NULL, NULL,
        jsonb_build_object('status_filter', p_status, 'rows', v_count),
        NULL, '{}'::jsonb
    );

    RETURN QUERY
    SELECT i.incident_id, i.kind, i.status, i.detected_at, i.reviewed_at,
           r.anonymous_pseudonym::TEXT, i.report_reference, i.notes,
           (SELECT count(*)::INT FROM jsonb_object_keys(i.labels)),
           (SELECT count(*)::INT FROM csam_evidence_access a
             WHERE a.incident_id = i.incident_id)
      FROM csam_incidents i
      LEFT JOIN users r ON r.user_id = i.reviewed_by
     WHERE p_status IS NULL OR i.status = p_status
     ORDER BY i.detected_at DESC
     LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 200), 500));
END $$;

CREATE OR REPLACE FUNCTION public.admin_read_csam_evidence(
    p_incident UUID,
    p_reason   TEXT
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_actor  UUID := auth.uid();
    v_inc    csam_incidents;
    v_who    users;
    v_fields TEXT[] := ARRAY['content_ref','author_id','labels'];
BEGIN
    IF NOT is_staff(v_actor, ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    PERFORM private.require_aal2();

    IF COALESCE(btrim(p_reason), '') = '' THEN
        RAISE EXCEPTION
          'reading child-safety evidence requires a stated reason: it is what the access review reads';
    END IF;

    SELECT * INTO v_inc FROM csam_incidents WHERE incident_id = p_incident;
    IF v_inc.incident_id IS NULL THEN
        RAISE EXCEPTION 'incident not found';
    END IF;

    SELECT * INTO v_who FROM users WHERE user_id = v_actor;

    IF v_inc.media_url IS NOT NULL THEN
        v_fields := v_fields || 'media_url'::TEXT;
    END IF;

    INSERT INTO csam_evidence_access
        (incident_id, actor_id, actor_pseudonym, actor_role, reason, fields_read)
    VALUES
        (p_incident, v_actor, v_who.anonymous_pseudonym, v_who.user_role::TEXT,
         btrim(p_reason), v_fields);

    PERFORM admin_log(
        'csam.evidence_read', 'csam_incident', p_incident, NULL, NULL,
        jsonb_build_object('fields', v_fields, 'incident_status', v_inc.status),
        btrim(p_reason), '{}'::jsonb
    );

    RETURN jsonb_build_object(
        'incident_id',    v_inc.incident_id,
        'kind',           v_inc.kind,
        'status',         v_inc.status,
        'content_ref',    v_inc.content_ref,
        'media_url',      v_inc.media_url,
        'author_id',      v_inc.author_id,
        'author_pseudonym',
            (SELECT a.anonymous_pseudonym FROM users a WHERE a.user_id = v_inc.author_id),
        'labels',         v_inc.labels,
        'detected_at',    v_inc.detected_at
    );
END $$;

-- =========================================================================
-- 4) Two more that never went through is_staff at all
--
-- My first inventory of this missed both. I grepped for the literal shape
-- `user_role = 'super_admin'` and these do not have it: admin_global_search
-- reads the role into a variable and compares the variable, and
-- admin_hot_feed_health uses `user_role IN (...)` inside an EXISTS. The
-- correct question was not "which functions match this pattern" but "which
-- functions mention user_role and never call is_staff", which is how both
-- turned up. Only the CSAM ones, queue_email, admin_log (which reads the role
-- to denormalise it into the audit row, not to authorise) and is_keeper_mode
-- (a Tribe concept, unrelated to staff) remain in that set.
--
-- admin_global_search keeps its variable: v_role is reused further down to
-- decide which result kinds a role may see, so the fix goes into the lookup —
-- a suspended account yields NULL and falls into the existing refusal — and
-- the body is otherwise byte-identical to 20261012090000.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.admin_global_search(
    p_query TEXT,
    p_limit INT DEFAULT 8
) RETURNS TABLE (
    kind        TEXT,
    id          UUID,
    title       TEXT,
    subtitle    TEXT,
    href        TEXT,
    occurred_at TIMESTAMPTZ
)
-- VOLATILE, not STABLE: this function writes an audit row. Marking it STABLE
-- made PostgREST run it inside a READ ONLY transaction, so every search failed
-- with "cannot execute INSERT in a read-only transaction" — and only through
-- PostgREST. Called from psql it worked, because that transaction was
-- read-write, so the mismarking was invisible until the real stack ran it.
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
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
END $$;

CREATE OR REPLACE FUNCTION public.admin_hot_feed_health()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  -- search_path is empty here, so is_staff must be schema-qualified.
  IF NOT public.is_staff((SELECT auth.uid()), ARRAY['super_admin','admin']) THEN
    RAISE EXCEPTION 'admin privileges required' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'row_count',
    (SELECT count(*) FROM public.mv_hot_posts)
  );
END
$function$;

SELECT public.record_migration(
  '20261018090000', 'staff_authorization_requires_active_account'
);

NOTIFY pgrst, 'reload schema';
