-- 0046_phase_a_infrastructure.sql
--
-- Phase A infrastructure schemas:
--   * subscriptions          — Stripe state mirror, read by SubscriptionService
--   * analytics_events       — server-side event log (mirrors what PostHog gets)
--   * admin_audit_log        — every admin/keeper action with actor + target
--   * email_outbox           — queued transactional emails, drained by dispatcher
--   * feature_flag_overrides — per-user / per-tribe flag overrides
--
-- All tables are RLS-locked. Writes go through SECURITY DEFINER RPCs
-- (or Edge Functions w/ service role); clients only ever read their
-- own slice of each table.

-- =========================================================================
-- 1) subscriptions  (Stripe mirror)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.subscriptions (
    subscription_id          TEXT PRIMARY KEY, -- Stripe sub id
    user_id                  UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    stripe_customer_id       TEXT NOT NULL,
    status                   TEXT NOT NULL CHECK (status IN (
                                'incomplete','trialing','active','past_due',
                                'canceled','unpaid','paused','free')),
    tier                     TEXT NOT NULL DEFAULT 'free' CHECK (tier IN (
                                'free','plus','pro','creator')),
    price_id                 TEXT,
    renews_at                TIMESTAMPTZ,
    canceled_at              TIMESTAMPTZ,
    current_period_start     TIMESTAMPTZ,
    current_period_end       TIMESTAMPTZ,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS subscriptions_user_idx
    ON public.subscriptions (user_id);
CREATE INDEX IF NOT EXISTS subscriptions_customer_idx
    ON public.subscriptions (stripe_customer_id);

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "subs self read" ON public.subscriptions;
CREATE POLICY "subs self read"
    ON public.subscriptions FOR SELECT
    USING (user_id = auth.uid());

GRANT SELECT ON public.subscriptions TO authenticated;

-- =========================================================================
-- 2) analytics_events  (server-side mirror of PostHog stream)
-- =========================================================================
-- Lets us run SQL over engagement without needing a separate warehouse.
-- Authored only by the analytics Edge Function (service role) or via
-- the `record_event` RPC the TelemetryService already uses.
CREATE TABLE IF NOT EXISTS public.analytics_events (
    event_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    name         TEXT NOT NULL CHECK (length(name) BETWEEN 2 AND 100),
    properties   JSONB NOT NULL DEFAULT '{}'::jsonb,
    env          TEXT,
    app_version  TEXT,
    platform     TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS analytics_events_name_time_idx
    ON public.analytics_events (name, created_at DESC);
CREATE INDEX IF NOT EXISTS analytics_events_user_time_idx
    ON public.analytics_events (user_id, created_at DESC)
    WHERE user_id IS NOT NULL;

ALTER TABLE public.analytics_events ENABLE ROW LEVEL SECURITY;

-- Only super_admin can read raw events. Everyone else has zero access.
DROP POLICY IF EXISTS "events admin read" ON public.analytics_events;
CREATE POLICY "events admin read"
    ON public.analytics_events FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM users u
         WHERE u.user_id = auth.uid()
           AND u.user_role = 'super_admin'
      )
    );

GRANT SELECT ON public.analytics_events TO authenticated;

-- =========================================================================
-- 3) admin_audit_log
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.admin_audit_log (
    audit_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE SET NULL,
    action       TEXT NOT NULL,
    target_kind  TEXT,    -- 'post' | 'comment' | 'user' | 'tribe' | 'whisper' | …
    target_id    TEXT,
    metadata     JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_audit_actor_time_idx
    ON public.admin_audit_log (actor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS admin_audit_target_idx
    ON public.admin_audit_log (target_kind, target_id);

ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "audit admin read" ON public.admin_audit_log;
CREATE POLICY "audit admin read"
    ON public.admin_audit_log FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM users u
         WHERE u.user_id = auth.uid()
           AND u.user_role = 'super_admin'
      )
    );

GRANT SELECT ON public.admin_audit_log TO authenticated;

CREATE OR REPLACE FUNCTION public.record_admin_action(
    p_action     TEXT,
    p_target_kind TEXT DEFAULT NULL,
    p_target_id  TEXT DEFAULT NULL,
    p_metadata   JSONB DEFAULT '{}'::jsonb
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_id UUID;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    INSERT INTO admin_audit_log (actor_id, action, target_kind, target_id, metadata)
    VALUES (v_me, p_action, p_target_kind, p_target_id, COALESCE(p_metadata, '{}'::jsonb))
    RETURNING audit_id INTO v_id;
    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.record_admin_action(TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_admin_action(TEXT, TEXT, TEXT, JSONB) TO authenticated;

-- =========================================================================
-- 4) email_outbox + queue_email RPC
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.email_outbox (
    outbox_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    template     TEXT NOT NULL CHECK (length(template) BETWEEN 2 AND 60),
    variables    JSONB NOT NULL DEFAULT '{}'::jsonb,
    status       TEXT NOT NULL DEFAULT 'queued'
                 CHECK (status IN ('queued','sending','sent','failed','skipped')),
    sent_at      TIMESTAMPTZ,
    last_error   TEXT,
    attempts     INT NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS email_outbox_status_idx
    ON public.email_outbox (status, created_at);
CREATE INDEX IF NOT EXISTS email_outbox_user_idx
    ON public.email_outbox (user_id);

ALTER TABLE public.email_outbox ENABLE ROW LEVEL SECURITY;

-- Caller sees only their own queue (useful for "we sent you an email"
-- copy + retry from the client).
DROP POLICY IF EXISTS "email outbox self read" ON public.email_outbox;
CREATE POLICY "email outbox self read"
    ON public.email_outbox FOR SELECT
    USING (user_id = auth.uid());

GRANT SELECT ON public.email_outbox TO authenticated;

CREATE OR REPLACE FUNCTION public.queue_email(
    p_template   TEXT,
    p_to_user_id UUID,
    p_variables  JSONB DEFAULT '{}'::jsonb
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_id UUID;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    -- Most templates target the caller; admins can target anyone. The
    -- dispatcher checks recipient consent before sending.
    IF p_to_user_id <> v_me THEN
      IF NOT EXISTS (
        SELECT 1 FROM users u
         WHERE u.user_id = v_me AND u.user_role = 'super_admin'
      ) THEN
        RAISE EXCEPTION 'not allowed to queue email for another user';
      END IF;
    END IF;
    INSERT INTO email_outbox (user_id, template, variables)
    VALUES (p_to_user_id, p_template, COALESCE(p_variables, '{}'::jsonb))
    RETURNING outbox_id INTO v_id;
    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.queue_email(TEXT, UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_email(TEXT, UUID, JSONB) TO authenticated;

-- =========================================================================
-- 5) feature_flag_overrides
-- =========================================================================
-- Per-user or per-tribe overrides for feature flags. PostHog handles
-- percentage rollouts and A/B tests centrally; this table is the
-- escape hatch for forced overrides (employee account, beta tribe).
CREATE TABLE IF NOT EXISTS public.feature_flag_overrides (
    override_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    flag_key     TEXT NOT NULL,
    user_id      UUID REFERENCES public.users(user_id) ON DELETE CASCADE,
    tribe_id     UUID REFERENCES public.tribes(tribe_id) ON DELETE CASCADE,
    bool_value   BOOLEAN,
    string_value TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((user_id IS NOT NULL) OR (tribe_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS flag_overrides_flag_idx
    ON public.feature_flag_overrides (flag_key);
CREATE INDEX IF NOT EXISTS flag_overrides_user_idx
    ON public.feature_flag_overrides (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS flag_overrides_tribe_idx
    ON public.feature_flag_overrides (tribe_id) WHERE tribe_id IS NOT NULL;

ALTER TABLE public.feature_flag_overrides ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "flag overrides self read" ON public.feature_flag_overrides;
CREATE POLICY "flag overrides self read"
    ON public.feature_flag_overrides FOR SELECT
    USING (
      user_id = auth.uid() OR EXISTS (
        SELECT 1 FROM users u
         WHERE u.user_id = auth.uid() AND u.user_role = 'super_admin'
      )
    );

GRANT SELECT ON public.feature_flag_overrides TO authenticated;

-- Convenience RPC the FeatureFlagsService can call for a single user.
CREATE OR REPLACE FUNCTION public.my_feature_flag_overrides()
RETURNS TABLE (flag_key TEXT, bool_value BOOLEAN, string_value TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RETURN; END IF;
    RETURN QUERY
    SELECT o.flag_key, o.bool_value, o.string_value
      FROM feature_flag_overrides o
     WHERE o.user_id = v_me
        OR o.tribe_id IN (
             SELECT tm.tribe_id FROM tribe_members tm WHERE tm.user_id = v_me
           );
END $$;

REVOKE ALL ON FUNCTION public.my_feature_flag_overrides() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_feature_flag_overrides() TO authenticated;

NOTIFY pgrst, 'reload schema';
