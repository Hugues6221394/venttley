-- 0022_admin_foundation.sql
--
-- Backend foundation for the super-admin console rebuild.
--
-- Pieces:
--   1) Extend user_role_type with admin / moderator / support / analyst /
--      read_only_auditor so we can grant the layered staff roles the
--      console exposes.
--   2) audit_log: append-only ledger of every privileged write. Trigger
--      blocks UPDATE/DELETE so the record stays trustworthy. Visible only
--      to super_admin / admin / read_only_auditor.
--   3) broadcasts: platform-wide messages (info, warning, critical, crisis).
--      Public-read so mobile clients can render the banner; admin-write.
--   4) feature_flags: keyed boolean+rollout state with public-read so the
--      mobile client can opt-in/out without a deploy.
--   5) SECURITY DEFINER admin_* RPCs that auto-write to audit_log. The
--      console never hits the raw tables for sensitive actions — it goes
--      through these so accountability is never optional.
--   6) admin_metrics_24h view: rolling 24h counts for the Control Center.

-- =========================================================================
-- 1) Role enum extension
-- =========================================================================
ALTER TYPE public.user_role_type ADD VALUE IF NOT EXISTS 'admin';
ALTER TYPE public.user_role_type ADD VALUE IF NOT EXISTS 'moderator';
ALTER TYPE public.user_role_type ADD VALUE IF NOT EXISTS 'support';
ALTER TYPE public.user_role_type ADD VALUE IF NOT EXISTS 'analyst';
ALTER TYPE public.user_role_type ADD VALUE IF NOT EXISTS 'read_only_auditor';

-- =========================================================================
-- 2) audit_log
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.audit_log (
    audit_id        UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id        UUID         REFERENCES public.users(user_id) ON DELETE SET NULL,
    actor_pseudonym TEXT         NOT NULL,
    actor_role      TEXT         NOT NULL,
    action          TEXT         NOT NULL,
    target_type     TEXT,
    target_id       UUID,
    target_label    TEXT,
    before_state    JSONB,
    after_state     JSONB,
    reason          TEXT,
    metadata        JSONB        NOT NULL DEFAULT '{}'::jsonb,
    ip              TEXT,
    user_agent      TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS audit_log_created_idx
    ON public.audit_log (created_at DESC);
CREATE INDEX IF NOT EXISTS audit_log_actor_idx
    ON public.audit_log (actor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS audit_log_target_idx
    ON public.audit_log (target_type, target_id);
CREATE INDEX IF NOT EXISTS audit_log_action_idx
    ON public.audit_log (action, created_at DESC);

CREATE OR REPLACE FUNCTION public.audit_log_immutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_log rows are immutable (op: %)', TG_OP;
END $$;

DROP TRIGGER IF EXISTS audit_log_no_mutate ON public.audit_log;
CREATE TRIGGER audit_log_no_mutate
    BEFORE UPDATE OR DELETE ON public.audit_log
    FOR EACH ROW EXECUTE FUNCTION public.audit_log_immutable();

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "audit read staff" ON public.audit_log;
CREATE POLICY "audit read staff" ON public.audit_log FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM public.users u
         WHERE u.user_id = auth.uid()
           AND u.user_role IN ('super_admin','admin','read_only_auditor')
      )
    );

GRANT SELECT ON public.audit_log TO authenticated;

-- =========================================================================
-- 3) broadcasts
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.broadcasts (
    broadcast_id    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    title           TEXT         NOT NULL,
    body            TEXT         NOT NULL,
    urgency         TEXT         NOT NULL CHECK (urgency IN ('info','warning','critical','crisis')),
    audience        JSONB        NOT NULL DEFAULT '{"scope":"all"}'::jsonb,
    scheduled_for   TIMESTAMPTZ,
    sent_at         TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ,
    sent_by         UUID         REFERENCES public.users(user_id) ON DELETE SET NULL,
    delivered_count INT          NOT NULL DEFAULT 0,
    dismissed_count INT          NOT NULL DEFAULT 0,
    is_active       BOOLEAN      NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS broadcasts_active_idx
    ON public.broadcasts (is_active, created_at DESC) WHERE is_active = true;

ALTER TABLE public.broadcasts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "broadcasts public read" ON public.broadcasts;
CREATE POLICY "broadcasts public read" ON public.broadcasts FOR SELECT
    USING (
      is_active = true
      AND (sent_at IS NOT NULL OR scheduled_for IS NOT NULL)
      AND (expires_at IS NULL OR expires_at > now())
    );

DROP POLICY IF EXISTS "broadcasts staff full read" ON public.broadcasts;
CREATE POLICY "broadcasts staff full read" ON public.broadcasts FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM public.users u
         WHERE u.user_id = auth.uid()
           AND u.user_role IN ('super_admin','admin','moderator','read_only_auditor')
      )
    );

GRANT SELECT ON public.broadcasts TO authenticated, anon;

-- =========================================================================
-- 4) feature_flags
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.feature_flags (
    flag_key      TEXT         PRIMARY KEY,
    description   TEXT,
    enabled       BOOLEAN      NOT NULL DEFAULT false,
    rollout_pct   INT          NOT NULL DEFAULT 0 CHECK (rollout_pct BETWEEN 0 AND 100),
    environment   TEXT         NOT NULL DEFAULT 'production',
    metadata      JSONB        NOT NULL DEFAULT '{}'::jsonb,
    updated_by    UUID         REFERENCES public.users(user_id) ON DELETE SET NULL,
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

ALTER TABLE public.feature_flags ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "flags public read" ON public.feature_flags;
CREATE POLICY "flags public read" ON public.feature_flags FOR SELECT USING (true);

GRANT SELECT ON public.feature_flags TO authenticated, anon;

INSERT INTO public.feature_flags (flag_key, description, enabled, rollout_pct) VALUES
    ('friends_system',          'Mutual-opt-in friend graph + Friends feed tab',      false, 0),
    ('plugz_creator_studio',    'Tribe-keeper analytics + community tools',           false, 0),
    ('confession_share_in_chat','Sharing post cards in DMs',                          false, 0),
    ('crisis_banner',           'Helpline banner on flagged posts (migration 0020)',  true,  100),
    ('personas',                'Anonymous persona handles (migration 0018)',          true,  100),
    ('whispers_24h',            '24h expiring posts',                                  true,  100),
    ('emotion_reactions',       'Six-emoji reactions on posts',                        true,  100),
    ('hot_feed_refresh',        'Cron-driven hot post materialised view',              true,  100)
ON CONFLICT (flag_key) DO NOTHING;

-- =========================================================================
-- 5) Helpers
-- =========================================================================
CREATE OR REPLACE FUNCTION public.is_staff(p_user UUID, p_roles TEXT[] DEFAULT ARRAY['super_admin','admin'])
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.users u
         WHERE u.user_id = p_user AND u.user_role::text = ANY(p_roles)
    );
$$;

-- Generic logger. Used by the admin_* RPCs below; can also be called
-- directly by Next.js server actions for actions that don't need a
-- dedicated RPC (e.g. login, sign-out, viewing sensitive pages).
CREATE OR REPLACE FUNCTION public.admin_log(
    p_action       TEXT,
    p_target_type  TEXT      DEFAULT NULL,
    p_target_id    UUID      DEFAULT NULL,
    p_target_label TEXT      DEFAULT NULL,
    p_before       JSONB     DEFAULT NULL,
    p_after        JSONB     DEFAULT NULL,
    p_reason       TEXT      DEFAULT NULL,
    p_metadata     JSONB     DEFAULT '{}'::jsonb
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_pseudonym TEXT;
    v_role      TEXT;
    v_audit_id  UUID;
BEGIN
    SELECT anonymous_pseudonym, user_role::text
      INTO v_pseudonym, v_role
      FROM users WHERE user_id = auth.uid();

    IF v_role IS NULL OR v_role NOT IN ('super_admin','admin','moderator','support','analyst') THEN
        RAISE EXCEPTION 'admin_log: caller is not staff';
    END IF;

    INSERT INTO audit_log (
        actor_id, actor_pseudonym, actor_role,
        action, target_type, target_id, target_label,
        before_state, after_state, reason, metadata
    ) VALUES (
        auth.uid(), v_pseudonym, v_role,
        p_action, p_target_type, p_target_id, p_target_label,
        p_before, p_after, p_reason, p_metadata
    ) RETURNING audit_id INTO v_audit_id;

    RETURN v_audit_id;
END $$;

REVOKE ALL ON FUNCTION public.admin_log(TEXT,TEXT,UUID,TEXT,JSONB,JSONB,TEXT,JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_log(TEXT,TEXT,UUID,TEXT,JSONB,JSONB,TEXT,JSONB) TO authenticated;

-- =========================================================================
-- 6) Privileged write RPCs
-- =========================================================================

-- Suspend or reactivate a user.
CREATE OR REPLACE FUNCTION public.admin_set_user_status(
    p_target UUID,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_before JSONB; v_after JSONB; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    IF p_status NOT IN ('active','suspended','banned','shadow_banned') THEN
        RAISE EXCEPTION 'invalid status %', p_status;
    END IF;

    SELECT to_jsonb(u), '@' || u.anonymous_pseudonym
      INTO v_before, v_label
      FROM users u WHERE u.user_id = p_target;
    IF v_before IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    UPDATE users SET account_status = p_status, updated_at = now()
     WHERE user_id = p_target;

    SELECT to_jsonb(u) INTO v_after FROM users u WHERE u.user_id = p_target;

    PERFORM admin_log(
        'user.set_status', 'user', p_target, v_label,
        jsonb_build_object('account_status', v_before->>'account_status'),
        jsonb_build_object('account_status', v_after->>'account_status'),
        p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_set_user_status(UUID,TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_user_status(UUID,TEXT,TEXT) TO authenticated;

-- Assign a role.
CREATE OR REPLACE FUNCTION public.admin_set_user_role(
    p_target UUID,
    p_role   TEXT,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_before TEXT; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can set roles';
    END IF;

    SELECT user_role::text, '@' || anonymous_pseudonym
      INTO v_before, v_label
      FROM users WHERE user_id = p_target;
    IF v_before IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    UPDATE users SET user_role = p_role::user_role_type, updated_at = now()
     WHERE user_id = p_target;

    PERFORM admin_log(
        'user.set_role', 'user', p_target, v_label,
        jsonb_build_object('user_role', v_before),
        jsonb_build_object('user_role', p_role),
        p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_set_user_role(UUID,TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_user_role(UUID,TEXT,TEXT) TO authenticated;

-- Soft-delete or restore a post.
CREATE OR REPLACE FUNCTION public.admin_set_post_deleted(
    p_post_id UUID,
    p_deleted BOOLEAN,
    p_reason  TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_before TIMESTAMPTZ; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT deleted_at, left(content, 80)
      INTO v_before, v_label
      FROM posts WHERE post_id = p_post_id;
    IF v_label IS NULL THEN RAISE EXCEPTION 'post not found'; END IF;

    UPDATE posts SET deleted_at = CASE WHEN p_deleted THEN now() ELSE NULL END
     WHERE post_id = p_post_id;

    PERFORM admin_log(
        CASE WHEN p_deleted THEN 'post.soft_delete' ELSE 'post.restore' END,
        'post', p_post_id, v_label,
        jsonb_build_object('deleted_at', v_before),
        jsonb_build_object('deleted_at', CASE WHEN p_deleted THEN now() END),
        p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_set_post_deleted(UUID,BOOLEAN,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_post_deleted(UUID,BOOLEAN,TEXT) TO authenticated;

-- Resolve a report, optionally with a follow-up action label.
CREATE OR REPLACE FUNCTION public.admin_resolve_report(
    p_report_id UUID,
    p_action    TEXT DEFAULT 'dismissed',
    p_note      TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_post_id UUID;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    UPDATE reports
       SET is_resolved = true, resolved_at = now()
     WHERE report_id = p_report_id
     RETURNING post_id INTO v_post_id;

    PERFORM admin_log(
        'report.resolve', 'report', p_report_id, NULL,
        NULL,
        jsonb_build_object('action', p_action),
        p_note, jsonb_build_object('post_id', v_post_id)
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_resolve_report(UUID,TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_resolve_report(UUID,TEXT,TEXT) TO authenticated;

-- Send (or schedule) a broadcast.
CREATE OR REPLACE FUNCTION public.admin_send_broadcast(
    p_title         TEXT,
    p_body          TEXT,
    p_urgency       TEXT,
    p_audience      JSONB,
    p_scheduled_for TIMESTAMPTZ DEFAULT NULL,
    p_expires_at    TIMESTAMPTZ DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    INSERT INTO broadcasts (title, body, urgency, audience, scheduled_for, expires_at,
                            sent_at, sent_by)
    VALUES (p_title, p_body, p_urgency, p_audience, p_scheduled_for, p_expires_at,
            CASE WHEN p_scheduled_for IS NULL THEN now() END, auth.uid())
    RETURNING broadcast_id INTO v_id;

    PERFORM admin_log(
        'broadcast.send', 'broadcast', v_id, p_title,
        NULL,
        jsonb_build_object('urgency', p_urgency, 'audience', p_audience),
        NULL, '{}'::jsonb
    );
    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.admin_send_broadcast(TEXT,TEXT,TEXT,JSONB,TIMESTAMPTZ,TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_send_broadcast(TEXT,TEXT,TEXT,JSONB,TIMESTAMPTZ,TIMESTAMPTZ) TO authenticated;

-- Toggle a feature flag.
CREATE OR REPLACE FUNCTION public.admin_set_flag(
    p_key         TEXT,
    p_enabled     BOOLEAN,
    p_rollout_pct INT  DEFAULT NULL,
    p_reason      TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before JSONB; v_after JSONB;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT to_jsonb(f) INTO v_before FROM feature_flags f WHERE flag_key = p_key;
    IF v_before IS NULL THEN
        INSERT INTO feature_flags (flag_key, enabled, rollout_pct, updated_by)
        VALUES (p_key, p_enabled, COALESCE(p_rollout_pct, 0), auth.uid());
    ELSE
        UPDATE feature_flags
           SET enabled = p_enabled,
               rollout_pct = COALESCE(p_rollout_pct, rollout_pct),
               updated_by = auth.uid(),
               updated_at = now()
         WHERE flag_key = p_key;
    END IF;

    SELECT to_jsonb(f) INTO v_after FROM feature_flags f WHERE flag_key = p_key;

    PERFORM admin_log(
        'flag.update', 'feature_flag', NULL, p_key,
        v_before, v_after, p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_set_flag(TEXT,BOOLEAN,INT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_flag(TEXT,BOOLEAN,INT,TEXT) TO authenticated;

-- Feature / unfeature / archive a tribe.
CREATE OR REPLACE FUNCTION public.admin_set_tribe_featured(
    p_tribe UUID,
    p_featured BOOLEAN,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    SELECT name INTO v_label FROM tribes WHERE tribe_id = p_tribe;
    IF v_label IS NULL THEN RAISE EXCEPTION 'tribe not found'; END IF;

    -- tribes table may not have a `featured` column yet; add if missing
    BEGIN
        UPDATE tribes SET is_featured = p_featured WHERE tribe_id = p_tribe;
    EXCEPTION WHEN undefined_column THEN
        ALTER TABLE public.tribes ADD COLUMN is_featured BOOLEAN NOT NULL DEFAULT false;
        UPDATE tribes SET is_featured = p_featured WHERE tribe_id = p_tribe;
    END;

    PERFORM admin_log(
        CASE WHEN p_featured THEN 'tribe.feature' ELSE 'tribe.unfeature' END,
        'tribe', p_tribe, v_label, NULL,
        jsonb_build_object('is_featured', p_featured), p_reason, '{}'::jsonb
    );
END $$;

REVOKE ALL ON FUNCTION public.admin_set_tribe_featured(UUID,BOOLEAN,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_tribe_featured(UUID,BOOLEAN,TEXT) TO authenticated;

-- Ensure the is_featured column exists even if no one calls the RPC.
ALTER TABLE public.tribes ADD COLUMN IF NOT EXISTS is_featured BOOLEAN NOT NULL DEFAULT false;

-- =========================================================================
-- 7) Control-center metrics view
-- =========================================================================
DROP VIEW IF EXISTS public.admin_metrics_24h;
CREATE VIEW public.admin_metrics_24h WITH (security_invoker = true) AS
SELECT
    (SELECT count(*) FROM users)                                                                          AS total_users,
    (SELECT count(*) FROM users WHERE created_at > now() - interval '24 hours')                            AS new_users_24h,
    (SELECT count(*) FROM users WHERE created_at > now() - interval '7 days')                              AS new_users_7d,
    (SELECT count(DISTINCT author_id) FROM posts WHERE created_at > now() - interval '24 hours')           AS dau_posters,
    (SELECT count(DISTINCT author_id) FROM posts_comments WHERE created_at > now() - interval '24 hours')  AS dau_commenters,
    (SELECT count(*) FROM tribes)                                                                          AS total_tribes,
    (SELECT count(*) FROM posts WHERE deleted_at IS NULL)                                                  AS live_posts,
    (SELECT count(*) FROM posts WHERE created_at > now() - interval '24 hours' AND deleted_at IS NULL)     AS posts_24h,
    (SELECT count(*) FROM posts_comments WHERE created_at > now() - interval '24 hours')                   AS comments_24h,
    (SELECT count(*) FROM reports WHERE is_resolved = false)                                               AS open_reports,
    (SELECT count(*) FROM posts WHERE crisis_level IS NOT NULL AND created_at > now() - interval '24 hours') AS crisis_posts_24h,
    (SELECT count(*) FROM broadcasts WHERE is_active AND (expires_at IS NULL OR expires_at > now()))       AS active_broadcasts;

GRANT SELECT ON public.admin_metrics_24h TO authenticated;

-- Hourly trend (last 24 buckets) for sparkline charts.
DROP VIEW IF EXISTS public.admin_signups_hourly;
CREATE VIEW public.admin_signups_hourly WITH (security_invoker = true) AS
SELECT date_trunc('hour', created_at) AS hour, count(*) AS signups
  FROM users
 WHERE created_at > now() - interval '24 hours'
 GROUP BY 1 ORDER BY 1;
GRANT SELECT ON public.admin_signups_hourly TO authenticated;

DROP VIEW IF EXISTS public.admin_posts_hourly;
CREATE VIEW public.admin_posts_hourly WITH (security_invoker = true) AS
SELECT date_trunc('hour', created_at) AS hour, count(*) AS posts
  FROM posts WHERE created_at > now() - interval '24 hours' AND deleted_at IS NULL
 GROUP BY 1 ORDER BY 1;
GRANT SELECT ON public.admin_posts_hourly TO authenticated;

DROP VIEW IF EXISTS public.admin_reports_daily;
CREATE VIEW public.admin_reports_daily WITH (security_invoker = true) AS
SELECT date_trunc('day', created_at) AS day, count(*) AS reports
  FROM reports WHERE created_at > now() - interval '30 days'
 GROUP BY 1 ORDER BY 1;
GRANT SELECT ON public.admin_reports_daily TO authenticated;

-- Per-region active user distribution.
DROP VIEW IF EXISTS public.admin_region_distribution;
CREATE VIEW public.admin_region_distribution WITH (security_invoker = true) AS
SELECT COALESCE(NULLIF(home_country, ''), 'unknown') AS country,
       count(*) AS users
  FROM users
 GROUP BY 1 ORDER BY 2 DESC;
GRANT SELECT ON public.admin_region_distribution TO authenticated;
