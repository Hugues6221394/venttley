-- 0086_analytics_rollups.sql
-- Make the active-user / retention / engagement analytics (migration 0084)
-- scale to millions of rows. The 0084 functions UNION-scanned posts, comments,
-- likes, tribe & DM messages and whispers on every call — fine at thousands of
-- rows, a timeout at millions.
--
-- Fix: a compact rollup `user_active_days` (one row per user per active day),
-- refreshed hourly by pg_cron. The analytics functions now read this small,
-- day-indexed table instead of the raw firehose. "Active" = did anything
-- (posted / commented / reacted / messaged / whispered) that day.

-- =========================================================================
-- 1) Rollup table
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.user_active_days (
    user_id UUID NOT NULL,
    day     DATE NOT NULL,
    PRIMARY KEY (user_id, day)
);
CREATE INDEX IF NOT EXISTS idx_user_active_days_day
    ON public.user_active_days (day);

-- Incrementally fold recent activity into the rollup. Idempotent
-- (ON CONFLICT DO NOTHING). Callable by cron (auth.uid() NULL) or staff.
CREATE OR REPLACE FUNCTION public.refresh_user_active_days(
    p_since DATE DEFAULT (current_date - 2)
) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n INT;
BEGIN
    IF auth.uid() IS NOT NULL
       AND NOT is_staff(auth.uid(), ARRAY['super_admin','admin','analyst']) THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    INSERT INTO public.user_active_days (user_id, day)
    SELECT DISTINCT uid, created_at::date
      FROM (
        SELECT author_id AS uid, created_at FROM posts          WHERE author_id IS NOT NULL
        UNION ALL SELECT author_id, created_at FROM posts_comments WHERE author_id IS NOT NULL
        UNION ALL SELECT user_id,   created_at FROM post_likes     WHERE user_id  IS NOT NULL
        UNION ALL SELECT sender_id, created_at FROM tribe_messages WHERE sender_id IS NOT NULL
        UNION ALL SELECT sender_id, created_at FROM chat_messages  WHERE sender_id IS NOT NULL
        UNION ALL SELECT author_id, created_at FROM whispers       WHERE author_id IS NOT NULL
      ) a
     WHERE created_at::date >= p_since
       AND created_at::date <= current_date
    ON CONFLICT (user_id, day) DO NOTHING;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

GRANT EXECUTE ON FUNCTION public.refresh_user_active_days(DATE) TO authenticated;

-- One-time backfill of recent history (migration runs as postgres → uid NULL).
SELECT public.refresh_user_active_days(current_date - 180);

-- Hourly refresh of the last 2 days so "today" is at most ~1h stale.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.unschedule('refresh_user_active_days')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'refresh_user_active_days');
SELECT cron.schedule('refresh_user_active_days', '25 * * * *',
                     $$ SELECT public.refresh_user_active_days(current_date - 2); $$);

-- =========================================================================
-- 2) Refactor the analytics functions to read the rollup
-- =========================================================================
CREATE OR REPLACE FUNCTION public.admin_active_users_daily(
    p_days INT DEFAULT 30
) RETURNS TABLE (day DATE, active_users INT, new_users INT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT public.is_staff(auth.uid(),
            ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    RETURN QUERY
    WITH bounds AS (
        SELECT (current_date - (greatest(1, p_days) - 1))::date AS start_day
    ),
    days AS (
        SELECT generate_series(
                   (SELECT start_day FROM bounds)::timestamp,
                   current_date::timestamp,
                   interval '1 day'
               )::date AS day
    ),
    active AS (
        SELECT uad.day AS day, count(*)::int AS n
          FROM public.user_active_days uad, bounds
         WHERE uad.day >= bounds.start_day
         GROUP BY uad.day
    ),
    signups AS (
        SELECT u.created_at::date AS day, count(*)::int AS n
          FROM public.users u, bounds
         WHERE u.created_at::date >= bounds.start_day
         GROUP BY 1
    )
    SELECT d.day, COALESCE(a.n, 0), COALESCE(s.n, 0)
      FROM days d
      LEFT JOIN active  a ON a.day = d.day
      LEFT JOIN signups s ON s.day = d.day
     ORDER BY d.day;
END $$;
GRANT EXECUTE ON FUNCTION public.admin_active_users_daily(INT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_engagement_totals()
RETURNS TABLE (
    total_users INT, active_1d INT, active_7d INT, active_30d INT,
    new_7d INT, new_30d INT, stickiness NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_dau INT; v_mau INT;
BEGIN
    IF NOT public.is_staff(auth.uid(),
            ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    SELECT count(DISTINCT user_id) INTO v_dau
      FROM public.user_active_days WHERE day >= current_date;
    SELECT count(DISTINCT user_id) INTO v_mau
      FROM public.user_active_days WHERE day >= current_date - 29;

    RETURN QUERY
    SELECT
        (SELECT count(*)::int FROM public.users),
        v_dau,
        (SELECT count(DISTINCT user_id)::int FROM public.user_active_days
          WHERE day >= current_date - 6),
        v_mau,
        (SELECT count(*)::int FROM public.users WHERE created_at > now() - interval '7 days'),
        (SELECT count(*)::int FROM public.users WHERE created_at > now() - interval '30 days'),
        CASE WHEN v_mau > 0 THEN round(v_dau::numeric / v_mau, 3) ELSE 0 END;
END $$;
GRANT EXECUTE ON FUNCTION public.admin_engagement_totals() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_new_user_retention(
    p_weeks INT DEFAULT 6
) RETURNS TABLE (
    cohort_week DATE, cohort_size INT, week_offset INT, retained INT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT public.is_staff(auth.uid(),
            ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    RETURN QUERY
    WITH weeks AS (SELECT greatest(1, least(p_weeks, 12)) AS w),
    cohorts AS (
        SELECT u.user_id, date_trunc('week', u.created_at)::date AS cohort_week
          FROM public.users u, weeks
         WHERE u.created_at >= date_trunc('week', now()) - ((weeks.w - 1) * interval '1 week')
    ),
    cohort_sizes AS (
        SELECT cohort_week, count(*)::int AS cohort_size FROM cohorts GROUP BY cohort_week
    ),
    user_weeks AS (
        SELECT DISTINCT uad.user_id AS uid, date_trunc('week', uad.day)::date AS act_week
          FROM public.user_active_days uad
         WHERE uad.user_id IN (SELECT user_id FROM cohorts)
    ),
    retention AS (
        SELECT c.cohort_week,
               ((uw.act_week - c.cohort_week) / 7)::int AS week_offset,
               count(DISTINCT c.user_id)::int AS retained
          FROM cohorts c
          JOIN user_weeks uw ON uw.uid = c.user_id AND uw.act_week >= c.cohort_week
         GROUP BY 1, 2
    )
    SELECT cs.cohort_week, cs.cohort_size, r.week_offset, r.retained
      FROM cohort_sizes cs
      JOIN retention r ON r.cohort_week = cs.cohort_week
     WHERE r.week_offset >= 0 AND r.week_offset < (SELECT w FROM weeks)
     ORDER BY cs.cohort_week, r.week_offset;
END $$;
GRANT EXECUTE ON FUNCTION public.admin_new_user_retention(INT) TO authenticated;

NOTIFY pgrst, 'reload schema';
