-- =========================================================================
-- CSAM evidence access: separately logged, tightly scoped
--
-- Closes the last engineering P0 in admin/README.md: "Access to CSAM and
-- highly sensitive evidence must be separately logged and tightly scoped."
-- Private-message bodies were handled in 20261005090000; CSAM evidence was
-- not, and the gap turned out to be larger than a missing log.
--
-- THE QUEUE HAS NEVER SHOWN A SINGLE INCIDENT.
--
-- public.csam_incidents carries an RLS policy admitting super_admin, and no
-- table grant at all: only postgres and service_role can SELECT it. The /csam
-- page reads it with the signed-in user's client, so the query has always
-- failed with 42501. Postgres checks the table privilege before it ever
-- reaches the policy, so the policy is dead code.
--
-- The failure mode is the worst one available for this particular screen.
-- The page destructures `const { data } = await ssr.from(...)` and discards
-- the error, so a null result renders the empty state: "No incidents —
-- nothing has been auto-detected." The most legally consequential queue in
-- the console reports all-clear while being broken. An operator cannot tell
-- "no child-safety material pending" from "this screen does not work".
--
-- The fix is deliberately not `GRANT SELECT ... TO authenticated`. That would
-- restore the page and keep the pattern this P0 exists to end: every page
-- load silently reading every incident's content reference, author identity
-- and classifier labels, with nothing written down. The table stays
-- unreadable and access goes through two functions — one that lists work
-- without disclosing evidence, one that discloses evidence and says so.
--
-- WHERE THE LINE IS DRAWN, AND WHY THERE
--
-- The queue returns kind, status, timestamps, the staff-written note and
-- report reference. It withholds content_ref, media_url, author_id and
-- labels. That is not a formality: content_ref is the post/whisper id, so
-- holding it is one query away from the material itself, and author_id names
-- a person against a child-safety allegation a classifier has not confirmed.
--
-- The queue therefore does NOT require AAL2, and the evidence read does.
-- Knowing that eleven incidents are waiting discloses nothing and is exactly
-- what an operator without their token on them still needs to know; reading
-- the evidence is the act worth stopping. admin_resolve_csam_incident already
-- required AAL2, so an operator without step-up can see the backlog and act
-- on none of it, which is the correct asymmetry.
--
-- media_url is returned by the evidence accessor and recorded as disclosed,
-- but the console deliberately does not render it as an image. Whether
-- reviewing this material in a browser is acceptable at all is a question for
-- counsel and trained specialists, not something to settle in a migration —
-- it is flagged in the README beside the CSAM items already waiting on them.
--
-- WHY A SECOND LEDGER WHEN audit_log EXISTS
--
-- "Separately logged" is the requirement. audit_log holds every privileged
-- action, so CSAM access review means filtering a general ledger that shares
-- its retention and its readership: /audit admits admin and
-- read_only_auditor, neither of which may see a CSAM incident. A dedicated
-- ledger can be reviewed, exported and retained on its own terms, which is
-- what a mandated-reporting posture needs. Both are written, on purpose.
--
-- csam_evidence_access carries NO foreign keys, matching audit_log, which
-- also has none. This is the lesson of 20261010090000 and 20261011090000: an
-- append-only guard refuses UPDATE, and `ON DELETE SET NULL` is an UPDATE, so
-- an FK to users would make the ledger block account deletion the moment
-- anyone read an incident. Actor identity is denormalised at write time
-- instead, which is also what an access review wants — the pseudonym and role
-- as they were when the access happened, not as they are today.
-- =========================================================================

-- =========================================================================
-- 1) The access ledger
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.csam_evidence_access (
    access_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- No FK, by design; see the header. An incident must never be deletable
    -- because someone once looked at it, and evidence rows outlive accounts.
    incident_id     UUID NOT NULL,
    actor_id        UUID,
    actor_pseudonym TEXT,
    actor_role      TEXT,
    -- Not nullable and not defaulted: an access with no stated purpose is the
    -- thing this ledger exists to make impossible.
    reason          TEXT NOT NULL,
    fields_read     TEXT[] NOT NULL DEFAULT '{}',
    accessed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.csam_evidence_access IS
  'Append-only record of every disclosure of CSAM incident evidence. Written by admin_read_csam_evidence only. Separate from audit_log so child-safety access can be reviewed, exported and retained independently.';

CREATE INDEX IF NOT EXISTS idx_csam_access_incident
    ON public.csam_evidence_access (incident_id, accessed_at DESC);
CREATE INDEX IF NOT EXISTS idx_csam_access_actor
    ON public.csam_evidence_access (actor_id, accessed_at DESC);

ALTER TABLE public.csam_evidence_access ENABLE ROW LEVEL SECURITY;

-- No grants and no policies: unreachable except through the definer
-- functions below. Stated rather than assumed, because csam_incidents was
-- protected the same way by accident and nobody noticed for months.
REVOKE ALL ON TABLE public.csam_evidence_access FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.csam_access_append_only()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    RAISE EXCEPTION
      'csam_evidence_access is append-only: an access record cannot be changed or removed once written (attempted %)',
      lower(TG_OP);
END $$;

DROP TRIGGER IF EXISTS csam_evidence_access_no_mutate ON public.csam_evidence_access;
CREATE TRIGGER csam_evidence_access_no_mutate
    BEFORE UPDATE OR DELETE ON public.csam_evidence_access
    FOR EACH ROW EXECUTE FUNCTION private.csam_access_append_only();

-- =========================================================================
-- 2) The queue: work to be done, without the evidence
-- =========================================================================

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
-- Deliberately VOLATILE. It writes an audit row, and PostgREST runs anything
-- marked STABLE inside a read-only transaction, which turns the write into a
-- runtime failure invisible from psql. admin_global_search shipped with
-- exactly that defect in 20261012090000.
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_actor UUID := auth.uid(); v_count INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users u
                    WHERE u.user_id = v_actor AND u.user_role = 'super_admin') THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    IF p_status IS NOT NULL
       AND p_status NOT IN ('detected','reported','cleared','false_positive') THEN
        RAISE EXCEPTION 'unknown status %', p_status;
    END IF;

    SELECT count(*) INTO v_count
      FROM csam_incidents i
     WHERE p_status IS NULL OR i.status = p_status;

    -- Listing the queue is itself worth a line. It discloses no evidence, so
    -- it is not written to csam_evidence_access — that ledger means
    -- "somebody saw material", and diluting it with page loads would make it
    -- useless for the review it exists to serve.
    PERFORM admin_log(
        'csam.queue_read', 'csam_incident', NULL, NULL, NULL,
        jsonb_build_object('status_filter', p_status, 'rows', v_count),
        NULL, '{}'::jsonb
    );

    RETURN QUERY
    SELECT i.incident_id,
           i.kind,
           i.status,
           i.detected_at,
           i.reviewed_at,
           r.anonymous_pseudonym::TEXT,
           i.report_reference,
           i.notes,
           -- The number of classifier labels, not the labels: "how confident
           -- and on what grounds" is evidence about a named person.
           (SELECT count(*)::INT FROM jsonb_object_keys(i.labels)),
           (SELECT count(*)::INT FROM csam_evidence_access a
             WHERE a.incident_id = i.incident_id)
      FROM csam_incidents i
      LEFT JOIN users r ON r.user_id = i.reviewed_by
     WHERE p_status IS NULL OR i.status = p_status
     ORDER BY i.detected_at DESC
     LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 200), 500));
END $$;

REVOKE ALL ON FUNCTION public.admin_csam_queue(TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_csam_queue(TEXT, INT) TO authenticated;

-- =========================================================================
-- 3) The evidence: disclosed on purpose, on the record
-- =========================================================================

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
    IF NOT EXISTS (SELECT 1 FROM users u
                    WHERE u.user_id = v_actor AND u.user_role = 'super_admin') THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    -- Step-up is required here and not on the queue. Seeing that work exists
    -- is not the same act as seeing the material.
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
        -- Cast required. An untyped literal on the right of || makes Postgres
        -- prefer anyarray || anyarray and try to parse 'media_url' as an
        -- array literal, which fails at runtime rather than at creation.
        v_fields := v_fields || 'media_url'::TEXT;
    END IF;

    -- Recorded BEFORE the row is returned. If the disclosure happens, the
    -- record of it is already in the same transaction; there is no ordering
    -- in which a reader sees the evidence and the ledger misses it.
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

REVOKE ALL ON FUNCTION public.admin_read_csam_evidence(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_read_csam_evidence(UUID, TEXT) TO authenticated;

-- =========================================================================
-- 4) Reading the access ledger
--
-- A log nobody can read is a log nobody keeps. read_only_auditor is admitted
-- because reviewing who looked at what is the whole point of the role, and
-- this returns no evidence — actor, reason, timestamp and which fields were
-- disclosed, never the fields themselves.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.admin_csam_access_log(
    p_incident UUID DEFAULT NULL,
    p_limit    INT  DEFAULT 200
) RETURNS TABLE (
    access_id       UUID,
    incident_id     UUID,
    actor_pseudonym TEXT,
    actor_role      TEXT,
    reason          TEXT,
    fields_read     TEXT[],
    accessed_at     TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','read_only_auditor']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    RETURN QUERY
    SELECT a.access_id, a.incident_id, a.actor_pseudonym, a.actor_role,
           a.reason, a.fields_read, a.accessed_at
      FROM csam_evidence_access a
     WHERE p_incident IS NULL OR a.incident_id = p_incident
     ORDER BY a.accessed_at DESC
     LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 200), 1000));
END $$;

REVOKE ALL ON FUNCTION public.admin_csam_access_log(UUID, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_csam_access_log(UUID, INT) TO authenticated;

-- =========================================================================
-- 5) Say why the delete was refused
--
-- 20261006090000 already refuses to delete an account with a CSAM incident in
-- 'detected' or 'reported' — I went looking for that gap and found it closed.
-- What it does not do is explain itself. The moderation-case branch names the
-- case and tells the operator to lift the hold; the CSAM branch raises a bare
-- 'legal_hold_active', so a super_admin deleting an account is told no and
-- given nothing to act on. They then have no reason to connect it to a
-- child-safety incident, and the plausible next move is to try again another
-- way.
--
-- The incident id is safe to name here: this path is only reachable through
-- admin_delete_user, which is super_admin-only, and super_admin is the only
-- role permitted to see a CSAM incident at all. Logic is unchanged — only
-- what the operator is told.
--
-- The function lives in `private`, not `public`. Writing the replacement
-- against public created a second, never-called copy and left the trigger
-- pointing at the original: the migration applied without a single error and
-- changed nothing. Only re-running the delete showed the old message. The
-- DROP below removes that stray if an earlier run of this file created it.
-- =========================================================================

DROP FUNCTION IF EXISTS public.prevent_legal_hold_user_delete();

CREATE OR REPLACE FUNCTION private.prevent_legal_hold_user_delete()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_case_id     UUID;
  v_incident_id UUID;
  v_status      TEXT;
BEGIN
  SELECT incident.incident_id, incident.status
    INTO v_incident_id, v_status
    FROM public.csam_incidents AS incident
   WHERE incident.author_id = OLD.user_id
     AND incident.status IN ('detected', 'reported')
   ORDER BY incident.detected_at
   LIMIT 1;

  IF v_incident_id IS NOT NULL THEN
    RAISE EXCEPTION
      'legal_hold_active: child-safety incident % on this account is %, not resolved; evidence and the link to this account must be preserved. Resolve it in /csam before deleting.',
      v_incident_id, v_status
      USING ERRCODE = 'P0001';
  END IF;

  -- A moderation case explicitly placed under legal hold.
  SELECT c.case_id INTO v_case_id
    FROM public.moderation_cases AS c
   WHERE c.subject_id = OLD.user_id
     AND c.legal_hold
   LIMIT 1;

  IF v_case_id IS NOT NULL THEN
    -- Name the case, so the operator can find the hold and decide whether to
    -- lift it rather than guessing why the delete was refused.
    RAISE EXCEPTION
      'legal_hold_active: moderation case % is under legal hold; lift it with admin_set_case_legal_hold before deleting this account',
      v_case_id
      USING ERRCODE = 'P0001';
  END IF;

  RETURN OLD;
END $$;

SELECT public.record_migration(
  '20261017090000', 'csam_evidence_access_logging'
);

NOTIFY pgrst, 'reload schema';
