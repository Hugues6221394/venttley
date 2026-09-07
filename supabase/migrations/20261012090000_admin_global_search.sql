-- One search box that reaches everything a super admin needs to reach.
--
-- admin/README.md, P1: "Make the top-bar global search functional. Today it is
-- visual only. Add exact-ID lookup and scoped search for users, content,
-- reports, cases, and Tribes without allowing broad extraction."
--
-- That last clause is the whole design constraint. A console for a
-- pseudonymous mental-health app must not ship a tool that dumps its member
-- list or reads the feed in bulk, so this is deliberately not a general query
-- interface:
--
--   * A minimum query length. Two characters would enumerate the platform one
--     prefix at a time; four will not.
--   * A hard result cap, applied per kind and again overall.
--   * Previews are truncated to 120 characters — enough to recognise a post,
--     not enough to read the feed through the search box.
--   * Exact-UUID lookup is separate from text search. Pasting an id finds the
--     one row it names; text never matches an id prefix, so ids cannot be
--     guessed a character at a time.
--   * Result kinds are gated by role, not just ordered by it. A moderator
--     searching an id that happens to be a CSAM incident gets nothing back,
--     rather than a row they cannot open.
--   * Every search is audited. On a platform whose promise is that members
--     are pseudonymous to each other, staff looking a person up is exactly
--     the act that should be reviewable — so the console submits a deliberate
--     search rather than querying as you type, and each one leaves a row.
--
-- Deliberately NOT searchable here: DM and private-room bodies. Those are
-- reachable only through a case, behind admin_read_case_sensitive_evidence,
-- which logs each access individually. A global search box that could find a
-- private message by its text would route around that entirely.

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
    SELECT user_role::text INTO v_role FROM users WHERE user_id = v_actor;
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

REVOKE ALL ON FUNCTION public.admin_global_search(TEXT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_global_search(TEXT, INT) TO authenticated;

SELECT public.record_migration(
  '20261012090000', 'admin_global_search'
);

NOTIFY pgrst, 'reload schema';
