-- 0094_csam_pipeline.sql
-- CSAM (child sexual abuse material) detection & mandated-reporting pipeline.
--
-- LEGAL/DESIGN NOTES — this path is deliberately different from ordinary nudity
-- blocking:
--   * PRESERVE, don't destroy. On detection the content is quarantined (hidden
--     from users via media_status='blocked') but the row + storage object are
--     kept as evidence. Providers are legally required to preserve reported
--     CSAM for a retention window and report it — never silently delete.
--   * An incident is opened for the Trust & Safety / legal team. Reporting to
--     the Rwanda Investigation Bureau (RIB, tel 166 / official cybercrime
--     channel) is a MANDATED, human + legal step (INHOPE can help route
--     cross-border material); this schema tracks it via report_reference but
--     does not fabricate an automated submission — that requires legal review.
--     NOTE: this pipeline is for CSAM (a crime) only. Suicidal/crisis cases are
--     NOT a police matter — they route to mental-health crisis care (the Safety
--     queue + crisis resources), never here.
--   * Access is super_admin ONLY. This is the most sensitive data in the system.
--
-- Detection itself happens in the `media-scan` edge function via the media
-- provider's CSAM model; on a hit it calls record_csam_incident() below.

CREATE TABLE IF NOT EXISTS public.csam_incidents (
    incident_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind            TEXT NOT NULL CHECK (kind IN ('post','whisper')),
    content_ref     UUID NOT NULL,        -- post_id / whisper_id (preserved)
    media_url       TEXT,                 -- storage reference (preserved, NOT rendered)
    author_id       UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    labels          JSONB NOT NULL DEFAULT '{}'::jsonb,
    status           TEXT NOT NULL DEFAULT 'detected'
                       CHECK (status IN ('detected','reported','cleared','false_positive')),
    report_reference TEXT,                -- authority's report ID, filled after the mandated report
    reviewed_by     UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    reviewed_at     TIMESTAMPTZ,
    notes           TEXT,
    detected_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_csam_incidents_status
    ON public.csam_incidents (status, detected_at DESC);

ALTER TABLE public.csam_incidents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.csam_incidents FROM anon, authenticated;

-- super_admin-only read (service role bypasses for the edge function).
DROP POLICY IF EXISTS "csam super_admin read" ON public.csam_incidents;
CREATE POLICY "csam super_admin read"
    ON public.csam_incidents FOR SELECT
    USING (EXISTS (SELECT 1 FROM public.users u
                    WHERE u.user_id = auth.uid() AND u.user_role = 'super_admin'));

-- Called by the media-scan edge function (service role) on a CSAM hit.
-- Quarantines the content (preserve, don't delete) and opens an incident.
CREATE OR REPLACE FUNCTION public.record_csam_incident(
    p_kind      TEXT,
    p_id        UUID,
    p_media_url TEXT,
    p_author    UUID,
    p_labels    JSONB DEFAULT '{}'::jsonb
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_incident UUID;
BEGIN
    -- Quarantine: hide from users. media_status='blocked' triggers the hide
    -- (soft) — the row + storage object remain as preserved evidence.
    IF p_kind = 'post' THEN
        UPDATE posts    SET media_status = 'blocked' WHERE post_id    = p_id;
    ELSIF p_kind = 'whisper' THEN
        UPDATE whispers SET media_status = 'blocked' WHERE whisper_id = p_id;
    ELSE
        RAISE EXCEPTION 'invalid kind %', p_kind;
    END IF;

    INSERT INTO public.csam_incidents (kind, content_ref, media_url, author_id, labels)
    VALUES (p_kind, p_id, p_media_url, p_author, coalesce(p_labels, '{}'::jsonb))
    RETURNING incident_id INTO v_incident;

    -- Highest-severity broadcast to super_admins via the audit ledger.
    PERFORM admin_log('csam.detected', 'csam_incident', v_incident, NULL,
                      NULL, jsonb_build_object('kind', p_kind, 'content_ref', p_id),
                      'Auto-detected — requires mandated review/report', p_labels);
    RETURN v_incident;
END $$;

-- super_admin resolves an incident (mark reported with the NCMEC id, or clear
-- a false positive — which un-quarantines the content). Audited.
CREATE OR REPLACE FUNCTION public.admin_resolve_csam_incident(
    p_incident_id UUID,
    p_status      TEXT,
    p_report_ref  TEXT DEFAULT NULL,
    p_notes       TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rec RECORD;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.users u
                    WHERE u.user_id = auth.uid() AND u.user_role = 'super_admin') THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
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
                      NULL, jsonb_build_object('status', p_status, 'report_reference', p_report_ref),
                      p_notes, '{}'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.record_csam_incident(TEXT, UUID, TEXT, UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_resolve_csam_incident(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_resolve_csam_incident(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- Open-incident count for the Safety/Ops chrome.
CREATE OR REPLACE FUNCTION public.admin_open_csam_count()
RETURNS INT LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
    SELECT count(*)::int FROM public.csam_incidents
     WHERE status = 'detected'
       AND EXISTS (SELECT 1 FROM public.users u
                    WHERE u.user_id = auth.uid() AND u.user_role = 'super_admin');
$$;
GRANT EXECUTE ON FUNCTION public.admin_open_csam_count() TO authenticated;

NOTIFY pgrst, 'reload schema';
