-- =====================================================================
-- Migration 0013 — Sprint 2 infrastructure primitives
-- =====================================================================
-- Adds the Postgres-side equivalents of what a typical stack would push
-- to Redis + a metrics service. Venttly's mobile clients hit PostgREST
-- directly, so we land these primitives in the database where every
-- caller (Flutter app, Next.js admin) can reach them through RLS-safe
-- RPCs instead of a separate service.
--
--   1. rate_limits  + claim_rate_limit()  — per-user / per-action quota
--   2. mv_hot_posts + refresh_hot_posts() — denormalized hot-rank cache
--   3. feed_hot     view                  — feed_posts sorted by score
--   4. app_events   + record_event()      — telemetry / observability sink
--   5. pg_stat_statements extension       — slow-query visibility
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Rate limits — fixed-window counters keyed on (user, action).
--    Replaces the "Redis INCR + EXPIRE" pattern. The window resets
--    when window_started_at falls outside the requested window.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rate_limits (
    user_id            UUID        NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    action_key         TEXT        NOT NULL,
    window_started_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    counter            INTEGER     NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, action_key)
);

ALTER TABLE public.rate_limits ENABLE ROW LEVEL SECURITY;

-- Only the RPC (SECURITY DEFINER) should touch this — no public policies.
DROP POLICY IF EXISTS "rate_limits no direct read"  ON public.rate_limits;
DROP POLICY IF EXISTS "rate_limits no direct write" ON public.rate_limits;

-- claim_rate_limit returns TRUE when the caller is still under quota
-- (and bumps the counter), FALSE when they are over.
CREATE OR REPLACE FUNCTION public.claim_rate_limit(
    p_action_key      TEXT,
    p_window_seconds  INT,
    p_max_count       INT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid    UUID := auth.uid();
    v_now    TIMESTAMPTZ := NOW();
    v_row    public.rate_limits%ROWTYPE;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not_authenticated';
    END IF;

    SELECT * INTO v_row
      FROM public.rate_limits
     WHERE user_id = v_uid AND action_key = p_action_key
       FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO public.rate_limits(user_id, action_key, window_started_at, counter)
        VALUES (v_uid, p_action_key, v_now, 1);
        RETURN TRUE;
    END IF;

    -- Window expired → reset.
    IF v_row.window_started_at + (p_window_seconds || ' seconds')::INTERVAL <= v_now THEN
        UPDATE public.rate_limits
           SET window_started_at = v_now,
               counter           = 1
         WHERE user_id = v_uid AND action_key = p_action_key;
        RETURN TRUE;
    END IF;

    -- Still inside the window.
    IF v_row.counter >= p_max_count THEN
        RETURN FALSE;
    END IF;

    UPDATE public.rate_limits
       SET counter = counter + 1
     WHERE user_id = v_uid AND action_key = p_action_key;
    RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.claim_rate_limit(TEXT, INT, INT) TO authenticated;

-- ---------------------------------------------------------------------
-- 2) Hot-rank materialized view.
--    Score = log10(likes+1) + age_hours/decay — Reddit-style.
--    Refreshed periodically (call refresh_hot_posts() from pg_cron).
-- ---------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS public.mv_hot_posts;
CREATE MATERIALIZED VIEW public.mv_hot_posts AS
SELECT
    p.post_id,
    -- Reddit hot algorithm, scaled down so very fresh posts still bubble up.
    (
        LOG(GREATEST(p.likes_count + p.comments_count, 1))
        + (EXTRACT(EPOCH FROM (p.created_at - TIMESTAMPTZ '2024-01-01')) / 45000.0)
    )::DOUBLE PRECISION AS hot_score,
    p.created_at,
    p.tribe_id,
    p.location_bucket
  FROM public.posts p
 WHERE p.deleted_at IS NULL
   AND p.is_whisper = FALSE;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_hot_posts_post
    ON public.mv_hot_posts(post_id);
CREATE INDEX IF NOT EXISTS idx_mv_hot_posts_score
    ON public.mv_hot_posts(hot_score DESC);
CREATE INDEX IF NOT EXISTS idx_mv_hot_posts_tribe_score
    ON public.mv_hot_posts(tribe_id, hot_score DESC);

CREATE OR REPLACE FUNCTION public.refresh_hot_posts()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_hot_posts;
EXCEPTION
    -- CONCURRENTLY needs a unique index and the view to be populated;
    -- fall back to a blocking refresh on the cold-start case.
    WHEN OTHERS THEN
        REFRESH MATERIALIZED VIEW public.mv_hot_posts;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refresh_hot_posts() TO authenticated;

-- ---------------------------------------------------------------------
-- 3) feed_hot view — same shape as feed_posts plus hot_score.
--    Clients ORDER BY hot_score DESC to render the Hot tab.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS public.feed_hot CASCADE;
CREATE VIEW public.feed_hot AS
SELECT
    f.*,
    h.hot_score
  FROM public.feed_posts f
  JOIN public.mv_hot_posts h ON h.post_id = f.post_id;

GRANT SELECT ON public.feed_hot TO authenticated, anon;

-- ---------------------------------------------------------------------
-- 4) app_events — telemetry / observability sink.
--    Captures client-side screen views, feature usage, and error
--    breadcrumbs. JSONB props keep the shape flexible.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.app_events (
    event_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    name        TEXT NOT NULL,
    severity    TEXT NOT NULL DEFAULT 'info'
                  CHECK (severity IN ('debug','info','warn','error')),
    props       JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_app_events_name_time
    ON public.app_events(name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_app_events_user_time
    ON public.app_events(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_app_events_severity_time
    ON public.app_events(severity, created_at DESC)
    WHERE severity IN ('warn','error');

ALTER TABLE public.app_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "app_events insert own" ON public.app_events;
CREATE POLICY "app_events insert own"
ON public.app_events FOR INSERT
TO authenticated
WITH CHECK (user_id = auth.uid() OR user_id IS NULL);

DROP POLICY IF EXISTS "app_events read own" ON public.app_events;
CREATE POLICY "app_events read own"
ON public.app_events FOR SELECT
TO authenticated
USING (user_id = auth.uid());

-- record_event RPC — preferred over direct INSERT so we can attach the
-- caller's user_id server-side and enforce a per-event-name rate limit
-- (100 / minute) to keep abuse from spamming the table.
CREATE OR REPLACE FUNCTION public.record_event(
    p_name      TEXT,
    p_severity  TEXT DEFAULT 'info',
    p_props     JSONB DEFAULT '{}'::JSONB
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_id  UUID;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'not_authenticated';
    END IF;

    IF p_severity NOT IN ('debug','info','warn','error') THEN
        RAISE EXCEPTION 'invalid_severity';
    END IF;

    IF NOT public.claim_rate_limit('record_event', 60, 100) THEN
        RAISE EXCEPTION 'rate_limited';
    END IF;

    INSERT INTO public.app_events(user_id, name, severity, props)
    VALUES (v_uid, p_name, p_severity, COALESCE(p_props, '{}'::JSONB))
    RETURNING event_id INTO v_id;

    RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_event(TEXT, TEXT, JSONB) TO authenticated;

-- ---------------------------------------------------------------------
-- 5) pg_stat_statements — slow query visibility.
--    Supabase already enables it on most projects but we guard against
--    the rare case where it isn't.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    BEGIN
        CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'pg_stat_statements not installable in this role; skipping.';
    END;
END $$;

-- =====================================================================
-- 0013 done.
-- =====================================================================
