-- 0084_analytics_metrics_and_geo.sql
-- Real analytics backbone for the admin console:
--   * Active-user metrics (DAU/WAU/MAU + stickiness) from genuine activity —
--     posts, comments, reactions, tribe & DM messages, whispers. No fake data,
--     no dependence on an events pipeline that may be empty.
--   * New-user retention cohort triangle.
--   * Coarse country-from-IP columns (country only — never city/precise) so
--     "where users come from" is real, not just self-reported home_country.
--
-- All read functions are SECURITY DEFINER gated by is_staff() (incl. analyst /
-- read_only_auditor) so aggregate analytics never leak PII to normal users and
-- staff without a super_admin role can still see the numbers.

-- =========================================================================
-- 1) Coarse geo columns (populated by the geo-capture edge function)
-- =========================================================================
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS last_country    TEXT,   -- ISO-3166 alpha-2, coarse
    ADD COLUMN IF NOT EXISTS last_country_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_users_last_country
    ON public.users (last_country)
    WHERE last_country IS NOT NULL;

-- =========================================================================
-- 2) Daily active users over a window (real activity union)
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
    activity AS (
        SELECT author_id AS uid, created_at FROM public.posts          WHERE author_id IS NOT NULL
        UNION ALL SELECT author_id, created_at FROM public.posts_comments WHERE author_id IS NOT NULL
        UNION ALL SELECT user_id,   created_at FROM public.post_likes     WHERE user_id  IS NOT NULL
        UNION ALL SELECT sender_id, created_at FROM public.tribe_messages WHERE sender_id IS NOT NULL
        UNION ALL SELECT sender_id, created_at FROM public.chat_messages  WHERE sender_id IS NOT NULL
        UNION ALL SELECT author_id, created_at FROM public.whispers       WHERE author_id IS NOT NULL
    ),
    days AS (
        SELECT generate_series(
                   (SELECT start_day FROM bounds)::timestamp,
                   current_date::timestamp,
                   interval '1 day'
               )::date AS day
    ),
    active AS (
        SELECT created_at::date AS day, count(DISTINCT uid)::int AS n
          FROM activity, bounds
         WHERE created_at::date >= bounds.start_day
         GROUP BY 1
    ),
    signups AS (
        SELECT created_at::date AS day, count(*)::int AS n
          FROM public.users, bounds
         WHERE created_at::date >= bounds.start_day
         GROUP BY 1
    )
    SELECT d.day,
           COALESCE(a.n, 0) AS active_users,
           COALESCE(s.n, 0) AS new_users
      FROM days d
      LEFT JOIN active  a ON a.day = d.day
      LEFT JOIN signups s ON s.day = d.day
     ORDER BY d.day;
END $$;

GRANT EXECUTE ON FUNCTION public.admin_active_users_daily(INT) TO authenticated;

-- =========================================================================
-- 3) Headline engagement totals (single row)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.admin_engagement_totals()
RETURNS TABLE (
    total_users  INT,
    active_1d    INT,
    active_7d    INT,
    active_30d   INT,
    new_7d       INT,
    new_30d      INT,
    stickiness   NUMERIC   -- DAU/MAU, 0..1
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT public.is_staff(auth.uid(),
            ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    RETURN QUERY
    WITH activity AS (
        SELECT author_id AS uid, created_at FROM public.posts          WHERE author_id IS NOT NULL
        UNION ALL SELECT author_id, created_at FROM public.posts_comments WHERE author_id IS NOT NULL
        UNION ALL SELECT user_id,   created_at FROM public.post_likes     WHERE user_id  IS NOT NULL
        UNION ALL SELECT sender_id, created_at FROM public.tribe_messages WHERE sender_id IS NOT NULL
        UNION ALL SELECT sender_id, created_at FROM public.chat_messages  WHERE sender_id IS NOT NULL
        UNION ALL SELECT author_id, created_at FROM public.whispers       WHERE author_id IS NOT NULL
    ),
    a1  AS (SELECT count(DISTINCT uid) n FROM activity WHERE created_at > now() - interval '1 day'),
    a7  AS (SELECT count(DISTINCT uid) n FROM activity WHERE created_at > now() - interval '7 days'),
    a30 AS (SELECT count(DISTINCT uid) n FROM activity WHERE created_at > now() - interval '30 days')
    SELECT
        (SELECT count(*)::int FROM public.users),
        (SELECT n::int FROM a1),
        (SELECT n::int FROM a7),
        (SELECT n::int FROM a30),
        (SELECT count(*)::int FROM public.users WHERE created_at > now() - interval '7 days'),
        (SELECT count(*)::int FROM public.users WHERE created_at > now() - interval '30 days'),
        CASE WHEN (SELECT n FROM a30) > 0
             THEN round((SELECT n FROM a1)::numeric / (SELECT n FROM a30), 3)
             ELSE 0 END;
END $$;

GRANT EXECUTE ON FUNCTION public.admin_engagement_totals() TO authenticated;

-- =========================================================================
-- 4) New-user retention cohorts (weekly triangle)
--    For each signup-week cohort, how many were still active N weeks later.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.admin_new_user_retention(
    p_weeks INT DEFAULT 6
) RETURNS TABLE (
    cohort_week  DATE,
    cohort_size  INT,
    week_offset  INT,
    retained     INT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT public.is_staff(auth.uid(),
            ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    RETURN QUERY
    WITH weeks AS (SELECT greatest(1, least(p_weeks, 12)) AS w),
    activity AS (
        SELECT author_id AS uid, created_at FROM public.posts          WHERE author_id IS NOT NULL
        UNION ALL SELECT author_id, created_at FROM public.posts_comments WHERE author_id IS NOT NULL
        UNION ALL SELECT user_id,   created_at FROM public.post_likes     WHERE user_id  IS NOT NULL
        UNION ALL SELECT sender_id, created_at FROM public.tribe_messages WHERE sender_id IS NOT NULL
        UNION ALL SELECT sender_id, created_at FROM public.chat_messages  WHERE sender_id IS NOT NULL
        UNION ALL SELECT author_id, created_at FROM public.whispers       WHERE author_id IS NOT NULL
    ),
    cohorts AS (
        SELECT u.user_id, date_trunc('week', u.created_at)::date AS cohort_week
          FROM public.users u, weeks
         WHERE u.created_at >= date_trunc('week', now()) - ((weeks.w - 1) * interval '1 week')
    ),
    cohort_sizes AS (
        SELECT cohort_week, count(*)::int AS cohort_size
          FROM cohorts GROUP BY cohort_week
    ),
    user_weeks AS (
        -- distinct (user, activity-week) pairs
        SELECT DISTINCT a.uid, date_trunc('week', a.created_at)::date AS act_week
          FROM activity a
         WHERE a.uid IN (SELECT user_id FROM cohorts)
    ),
    retention AS (
        SELECT c.cohort_week,
               -- both are week-truncated dates, so their difference in days
               -- is a clean multiple of 7.
               ((uw.act_week - c.cohort_week) / 7)::int AS week_offset,
               count(DISTINCT c.user_id)::int AS retained
          FROM cohorts c
          JOIN user_weeks uw
            ON uw.uid = c.user_id
           AND uw.act_week >= c.cohort_week
         GROUP BY 1, 2
    )
    SELECT cs.cohort_week, cs.cohort_size, r.week_offset, r.retained
      FROM cohort_sizes cs
      JOIN retention r ON r.cohort_week = cs.cohort_week
     WHERE r.week_offset >= 0
       AND r.week_offset < (SELECT w FROM weeks)
     ORDER BY cs.cohort_week, r.week_offset;
END $$;

GRANT EXECUTE ON FUNCTION public.admin_new_user_retention(INT) TO authenticated;

-- =========================================================================
-- 5) Real geo distribution — coarse country from IP, falling back to the
--    self-reported home_country so early rows aren't blank.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.admin_geo_distribution(
    p_limit INT DEFAULT 12
) RETURNS TABLE (country TEXT, users INT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT public.is_staff(auth.uid(),
            ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    RETURN QUERY
    SELECT upper(COALESCE(NULLIF(u.last_country, ''),
                          NULLIF(u.home_country, ''), 'Unknown')) AS country,
           count(*)::int AS users
      FROM public.users u
     GROUP BY 1
     ORDER BY 2 DESC
     LIMIT greatest(1, p_limit);
END $$;

GRANT EXECUTE ON FUNCTION public.admin_geo_distribution(INT) TO authenticated;

NOTIFY pgrst, 'reload schema';
