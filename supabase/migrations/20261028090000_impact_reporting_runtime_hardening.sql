-- Runtime hardening for the impact evidence platform.
--
-- This migration keeps report reads actor-bound, gives delayed outcomes a
-- bounded recomputation window, and adds the time-first access paths used by
-- the nightly batch. It stores no authored content or direct identifiers.

-- These metrics are daily uniques that are additive as person-days, not as
-- cross-window unique people. Keep the label and formula mathematically honest.
UPDATE private.impact_metric_definitions
   SET title = 'Active person-days',
       description = 'Sum of daily distinct people who performed a meaningful platform action. A person active on multiple days is counted once per active day; this is not a cross-window unique-person count.',
       formula = 'sum(daily count(distinct actor across canonical activity tables))',
       updated_at = now()
 WHERE metric_key = 'reach.active_users';

UPDATE private.impact_metric_definitions
   SET title = 'Support participant-days',
       description = 'Sum of daily distinct people who commented on another person''s Vent. A person active on multiple days is counted once per day. This is participation, not proof of support quality.',
       formula = 'sum(daily count(distinct non-author commenters))',
       updated_at = now()
 WHERE metric_key = 'community.support_participants';

-- Direct report lookup prevents an older immutable snapshot from becoming
-- unexportable merely because it fell outside the recent-report list.
CREATE OR REPLACE FUNCTION public.admin_impact_report(p_report UUID)
RETURNS TABLE (
  report_id UUID,report_kind TEXT,title TEXT,audience TEXT,window_start DATE,window_end DATE,
  country_source TEXT,country_filter TEXT,status TEXT,methodology_version TEXT,
  minimum_cohort INTEGER,generated_at TIMESTAMPTZ,published_at TIMESTAMPTZ,checksum TEXT,metric_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
  SELECT r.report_id,r.report_kind,r.title,r.audience,r.window_start,r.window_end,r.country_source,r.country_filter,
         r.status,r.methodology_version,r.minimum_cohort,r.generated_at,r.published_at,r.checksum,
         (SELECT count(*)::INTEGER FROM private.impact_report_values v WHERE v.report_id=r.report_id)
    FROM private.impact_report_snapshots r
   WHERE r.report_id=p_report;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_impact_report(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_impact_report(UUID) TO authenticated;

-- Response rates, case decisions, and Day-7 retention mature after their
-- cohort date. Recompute a bounded window idempotently instead of freezing
-- incomplete first-pass values forever.
CREATE OR REPLACE FUNCTION private.refresh_impact_lookback(p_days INTEGER DEFAULT 30)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_offset INTEGER;
BEGIN
  IF p_days IS NULL OR p_days < 1 OR p_days > 45 THEN
    RAISE EXCEPTION 'invalid_impact_lookback' USING ERRCODE='22023';
  END IF;
  FOR v_offset IN 1..p_days LOOP
    PERFORM private.refresh_impact_daily(current_date-v_offset);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION private.refresh_impact_lookback(INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.refresh_impact_lookback(INTEGER) TO service_role;

-- The batch filters by time before grouping. Time-first indexes avoid walking
-- the historical tail as these high-write tables grow into the millions.
CREATE INDEX IF NOT EXISTS users_impact_created_idx
  ON public.users (created_at, user_id);
CREATE INDEX IF NOT EXISTS posts_impact_created_idx
  ON public.posts (created_at, author_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS posts_comments_impact_created_idx
  ON public.posts_comments (created_at, author_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS post_likes_impact_created_idx
  ON public.post_likes (created_at, user_id);
CREATE INDEX IF NOT EXISTS tribe_messages_impact_created_idx
  ON public.tribe_messages (created_at, sender_id);
CREATE INDEX IF NOT EXISTS chat_messages_impact_created_idx
  ON public.chat_messages (created_at, sender_id);
CREATE INDEX IF NOT EXISTS reports_impact_created_idx
  ON public.reports (created_at);
CREATE INDEX IF NOT EXISTS moderation_cases_impact_opened_idx
  ON public.moderation_cases (opened_at) INCLUDE (decided_at);

SELECT cron.schedule(
  'venttly-impact-daily-v1',
  '20 2 * * *',
  $job$SELECT private.refresh_impact_lookback(30); SELECT private.run_impact_data_quality(current_date);$job$
);

-- The ledger, so a database can say whether it has run this.
SELECT public.record_migration('20261028090000', 'impact_reporting_runtime_hardening');

NOTIFY pgrst, 'reload schema';
