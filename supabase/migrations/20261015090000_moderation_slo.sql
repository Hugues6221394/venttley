-- Service-level metrics for moderation, computed from what the case model
-- already persists.
--
-- admin/README.md, P1: "Define and instrument queue age, time to first action,
-- time to resolution, reversal/appeal rate, repeat-offender rate, action
-- failure rate, audit-write failure rate, notification delivery, media-scan
-- latency, and crisis/CSAM acknowledgement SLOs. Metrics must not contain
-- authored content."
--
-- Nothing here reads content: the function returns names, numbers and units.
--
-- TWO OF THOSE METRICS ARE NOT COMPUTABLE AND ARE DELIBERATELY ABSENT rather
-- than approximated, because a dashboard that shows a plausible number for
-- something it cannot measure is worse than one that admits the gap:
--
--   * audit-write failure rate — nothing records a failed audit write. The
--     writes are now inside the same transaction as their mutation, so a
--     failure rolls the action back and leaves no trace by design. Measuring
--     it would mean logging failures somewhere outside that transaction.
--   * notification delivery — public.notifications has is_read but no
--     delivered_at, so "delivered" cannot be distinguished from "inserted".
--     push_delivery_outbox does track status and sent_at, so push delivery IS
--     reported below; in-app notification delivery is not.
--
-- THE TARGETS BELOW ARE PROVISIONAL. The 15-minute crisis target comes from
-- private.case_sla, which is the product's own policy. The rest are
-- engineering placeholders chosen to be plausible, not decisions anyone has
-- signed off. They are stated in one place so they can be argued with, and
-- should move into configuration once product sets them.

CREATE OR REPLACE FUNCTION public.admin_moderation_slo(
    p_days INT DEFAULT 30
) RETURNS TABLE (
    section     TEXT,
    metric      TEXT,
    value       NUMERIC,
    unit        TEXT,
    target      NUMERIC,
    target_kind TEXT,      -- 'max' | 'min' | 'none'
    met         BOOLEAN,
    sample      INT,
    -- Whether the verdict depends on having enough observations. True for
    -- percentiles and rates, where a small denominator makes the number
    -- meaningless. False for an absolute count of a bad condition — "0 jobs
    -- stuck right now" is definitive, and treating it as a thin sample would
    -- render the good state as unmeasured.
    needs_sample BOOLEAN
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_since TIMESTAMPTZ := now() - make_interval(days => LEAST(GREATEST(COALESCE(p_days,30),1),365));
BEGIN
    -- Aggregate metrics, so the analyst and auditor roles belong here: this is
    -- the same tier of access as /analytics and /ops, and there is no content
    -- to leak.
    IF NOT is_staff(auth.uid(),
         ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    RETURN QUERY
    WITH
    resolved AS (
        SELECT c.*,
               EXTRACT(EPOCH FROM (c.first_action_at - c.opened_at))/60.0 AS ttfa_min,
               EXTRACT(EPOCH FROM (c.decided_at     - c.opened_at))/60.0 AS ttr_min
          FROM moderation_cases c
         WHERE c.decided_at IS NOT NULL AND c.opened_at >= v_since
    ),
    open_cases AS (
        SELECT c.* FROM moderation_cases c WHERE c.status <> 'resolved'
    ),
    appeals AS (
        SELECT a.* FROM moderation_appeals a WHERE a.created_at >= v_since
    ),
    rows AS (
        -- ---------------- queue ----------------
        SELECT 'Queue'::text, 'Open cases'::text,
               count(*)::numeric, 'cases'::text,
               NULL::numeric, 'none'::text, NULL::boolean, count(*)::int, false
          FROM open_cases

        UNION ALL
        SELECT 'Queue', 'Oldest open case',
               COALESCE(round(MAX(EXTRACT(EPOCH FROM (now() - opened_at))/60.0), 1), 0),
               'minutes', NULL, 'none', NULL, count(*)::int, false
          FROM open_cases

        UNION ALL
        -- A case past its deadline and still unresolved. The deadline is
        -- persisted, so this is a fact rather than a recomputation.
        SELECT 'Queue', 'Open past SLA',
               count(*)::numeric, 'cases', 0, 'max',
               count(*) = 0, count(*)::int, false
          FROM open_cases WHERE sla_due_at < now()

        UNION ALL
        -- ---------------- speed ----------------
        SELECT 'Speed', 'Time to first action (p50)',
               COALESCE(round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ttfa_min)::numeric, 1), 0),
               'minutes', NULL, 'none', NULL, count(*)::int, true
          FROM resolved WHERE ttfa_min IS NOT NULL

        UNION ALL
        SELECT 'Speed', 'Time to first action (p90)',
               COALESCE(round(percentile_cont(0.9) WITHIN GROUP (ORDER BY ttfa_min)::numeric, 1), 0),
               'minutes', 60, 'max',
               COALESCE(percentile_cont(0.9) WITHIN GROUP (ORDER BY ttfa_min), 0) <= 60,
               count(*)::int, true
          FROM resolved WHERE ttfa_min IS NOT NULL

        UNION ALL
        SELECT 'Speed', 'Time to resolution (p90)',
               COALESCE(round(percentile_cont(0.9) WITHIN GROUP (ORDER BY ttr_min)::numeric, 1), 0),
               'minutes', 1440, 'max',
               COALESCE(percentile_cont(0.9) WITHIN GROUP (ORDER BY ttr_min), 0) <= 1440,
               count(*)::int, true
          FROM resolved WHERE ttr_min IS NOT NULL

        UNION ALL
        -- The product's own 15-minute crisis target, from private.case_sla.
        SELECT 'Speed', 'Crisis acknowledgement (p90)',
               COALESCE(round(percentile_cont(0.9) WITHIN GROUP (ORDER BY ttfa_min)::numeric, 1), 0),
               'minutes', 15, 'max',
               COALESCE(percentile_cont(0.9) WITHIN GROUP (ORDER BY ttfa_min), 0) <= 15,
               count(*)::int, true
          FROM resolved WHERE severity = 'critical' AND ttfa_min IS NOT NULL

        UNION ALL
        SELECT 'Speed', 'Met SLA before first action',
               COALESCE(round(100.0 * count(*) FILTER (WHERE first_action_at <= sla_due_at)
                              / NULLIF(count(*), 0), 1), 0),
               'percent', 95, 'min',
               COALESCE(100.0 * count(*) FILTER (WHERE first_action_at <= sla_due_at)
                        / NULLIF(count(*), 0), 100) >= 95,
               count(*)::int, true
          FROM resolved WHERE first_action_at IS NOT NULL

        UNION ALL
        -- ---------------- quality ----------------
        -- A high reversal rate means the original decisions were wrong, which
        -- is the one number here that judges the moderators rather than the
        -- queue. Kept next to the appeal rate so a low reversal rate on a
        -- tiny sample is visible as such.
        SELECT 'Quality', 'Appeals filed',
               count(*)::numeric, 'appeals', NULL, 'none', NULL, count(*)::int, false
          FROM appeals

        UNION ALL
        SELECT 'Quality', 'Appeals overturned',
               COALESCE(round(100.0 * count(*) FILTER (WHERE status = 'overturned')
                              / NULLIF(count(*) FILTER (WHERE status IN ('upheld','overturned')), 0), 1), 0),
               'percent', 10, 'max',
               COALESCE(100.0 * count(*) FILTER (WHERE status = 'overturned')
                        / NULLIF(count(*) FILTER (WHERE status IN ('upheld','overturned')), 0), 0) <= 10,
               count(*) FILTER (WHERE status IN ('upheld','overturned'))::int, true
          FROM appeals

        UNION ALL
        SELECT 'Quality', 'Subjects with repeat cases',
               COALESCE(round(100.0 * count(*) FILTER (WHERE n > 1) / NULLIF(count(*), 0), 1), 0),
               'percent', NULL, 'none', NULL, count(*)::int, true
          FROM (SELECT subject_id, count(*) AS n
                  FROM moderation_cases
                 WHERE subject_id IS NOT NULL AND opened_at >= v_since
                 GROUP BY subject_id) s

        UNION ALL
        -- ---------------- pipelines ----------------
        SELECT 'Pipelines', 'Media scan (p90)',
               COALESCE(round(percentile_cont(0.9) WITHIN GROUP (
                 ORDER BY EXTRACT(EPOCH FROM (completed_at - created_at))/60.0)::numeric, 1), 0),
               'minutes', 5, 'max',
               COALESCE(percentile_cont(0.9) WITHIN GROUP (
                 ORDER BY EXTRACT(EPOCH FROM (completed_at - created_at))/60.0), 0) <= 5,
               count(*)::int, true
          FROM media_scan_jobs
         WHERE completed_at IS NOT NULL AND created_at >= v_since

        UNION ALL
        SELECT 'Pipelines', 'Media scans stuck',
               count(*)::numeric, 'jobs', 0, 'max', count(*) = 0, count(*)::int, false
          FROM media_scan_jobs
         WHERE completed_at IS NULL AND created_at < now() - interval '1 hour'

        UNION ALL
        -- Push is the one delivery path that records an outcome, so it is the
        -- one reported. In-app notification delivery is not measurable.
        SELECT 'Pipelines', 'Push deliveries failed',
               COALESCE(round(100.0 * count(*) FILTER (WHERE status = 'failed')
                              / NULLIF(count(*), 0), 1), 0),
               'percent', 1, 'max',
               COALESCE(100.0 * count(*) FILTER (WHERE status = 'failed')
                        / NULLIF(count(*), 0), 0) <= 1,
               count(*)::int, true
          FROM push_delivery_outbox WHERE created_at >= v_since

        UNION ALL
        SELECT 'Pipelines', 'Push deliveries stuck',
               count(*)::numeric, 'messages', 0, 'max', count(*) = 0, count(*)::int, false
          FROM push_delivery_outbox
         WHERE status NOT IN ('sent','failed') AND created_at < now() - interval '1 hour'
    )
    SELECT r.* FROM rows r;
END $$;

REVOKE ALL ON FUNCTION public.admin_moderation_slo(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_moderation_slo(INT) TO authenticated;

SELECT public.record_migration(
  '20261015090000', 'moderation_slo'
);

NOTIFY pgrst, 'reload schema';
