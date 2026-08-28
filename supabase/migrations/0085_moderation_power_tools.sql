-- 0085_moderation_power_tools.sql
-- Moderation power tools:
--   1) Temp-ban LADDER — escalating suspensions (24h → 7d → 30d → permanent)
--      tracked per user, with automatic expiry via pg_cron.
--   2) BULK report resolution.
--   3) AUTOMOD keyword rules — a staff-managed dictionary the mobile safety
--      classifier loads to extend its built-in keyword lists without a deploy.
--   4) Per-user report HISTORY function.
--
-- Ladder uses account_status='suspended' + suspended_until (NULL while
-- suspended = permanent), so it never touches the account_status CHECK enum.

-- =========================================================================
-- 1) Ladder columns + escalating-suspend RPC + auto-expiry
-- =========================================================================
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS suspended_until  TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS suspension_count INT NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_users_suspended_until
    ON public.users (suspended_until)
    WHERE suspended_until IS NOT NULL;

-- Apply the next rung of the ladder to a user. Tier is driven by how many
-- times they've already been suspended:
--   0 → 24h, 1 → 7d, 2 → 30d, 3+ → permanent.
CREATE OR REPLACE FUNCTION public.admin_suspend_user_ladder(
    p_target UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_count    INT;
    v_label    TEXT;
    v_duration INTERVAL;
    v_until    TIMESTAMPTZ;
    v_tier     TEXT;
    v_before   JSONB;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;

    SELECT suspension_count, '@' || anonymous_pseudonym, to_jsonb(u)
      INTO v_count, v_label, v_before
      FROM users u WHERE u.user_id = p_target;
    IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    v_duration := CASE v_count
                    WHEN 0 THEN interval '24 hours'
                    WHEN 1 THEN interval '7 days'
                    WHEN 2 THEN interval '30 days'
                    ELSE NULL           -- permanent
                  END;
    v_until := CASE WHEN v_duration IS NULL THEN NULL ELSE now() + v_duration END;
    v_tier  := CASE v_count
                    WHEN 0 THEN '24h'
                    WHEN 1 THEN '7d'
                    WHEN 2 THEN '30d'
                    ELSE 'permanent'
               END;

    UPDATE users
       SET account_status   = 'suspended',
           suspended_until  = v_until,
           suspension_count = suspension_count + 1,
           updated_at       = now()
     WHERE user_id = p_target;

    PERFORM admin_log(
        'user.suspend_ladder', 'user', p_target, v_label,
        jsonb_build_object('account_status', v_before->>'account_status',
                           'suspension_count', v_count),
        jsonb_build_object('account_status', 'suspended',
                           'suspension_count', v_count + 1,
                           'suspended_until', v_until, 'tier', v_tier),
        p_reason, jsonb_build_object('tier', v_tier)
    );

    RETURN jsonb_build_object('tier', v_tier, 'suspended_until', v_until,
                              'suspension_count', v_count + 1);
END $$;

REVOKE ALL ON FUNCTION public.admin_suspend_user_ladder(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_suspend_user_ladder(UUID, TEXT) TO authenticated;

-- Lift a suspension early (keeps suspension_count for ladder history).
CREATE OR REPLACE FUNCTION public.admin_lift_suspension(
    p_target UUID,
    p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    SELECT '@' || anonymous_pseudonym INTO v_label FROM users WHERE user_id = p_target;
    IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    UPDATE users
       SET account_status = 'active', suspended_until = NULL, updated_at = now()
     WHERE user_id = p_target;

    PERFORM admin_log('user.lift_suspension', 'user', p_target, v_label,
                      NULL, jsonb_build_object('account_status', 'active'),
                      p_reason, '{}'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.admin_lift_suspension(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_lift_suspension(UUID, TEXT) TO authenticated;

-- Auto-expiry: flip lapsed temp-suspensions back to active every hour.
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE OR REPLACE FUNCTION public.expire_due_suspensions()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n INT;
BEGIN
    UPDATE users
       SET account_status = 'active', suspended_until = NULL, updated_at = now()
     WHERE account_status = 'suspended'
       AND suspended_until IS NOT NULL
       AND suspended_until < now();
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

-- (Re)schedule the hourly expiry sweep.
SELECT cron.unschedule('expire_suspensions')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'expire_suspensions');
SELECT cron.schedule('expire_suspensions', '7 * * * *',
                     $$ SELECT public.expire_due_suspensions(); $$);

-- =========================================================================
-- 2) Bulk report resolution
-- =========================================================================
CREATE OR REPLACE FUNCTION public.admin_bulk_resolve_reports(
    p_report_ids UUID[],
    p_action     TEXT DEFAULT 'dismissed',
    p_note       TEXT DEFAULT NULL
) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID; v_n INT := 0;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']) THEN
        RAISE EXCEPTION 'forbidden';
    END IF;
    FOREACH v_id IN ARRAY COALESCE(p_report_ids, ARRAY[]::UUID[]) LOOP
        UPDATE reports SET is_resolved = true, resolved_at = now()
         WHERE report_id = v_id AND is_resolved = false;
        IF FOUND THEN
            v_n := v_n + 1;
            PERFORM admin_log('report.bulk_resolve', 'report', v_id, NULL,
                              NULL, jsonb_build_object('action', p_action),
                              p_note, '{}'::jsonb);
        END IF;
    END LOOP;
    RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION public.admin_bulk_resolve_reports(UUID[], TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_bulk_resolve_reports(UUID[], TEXT, TEXT) TO authenticated;

-- =========================================================================
-- 3) Automod keyword rules
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.automod_rules (
    rule_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pattern    TEXT NOT NULL CHECK (length(pattern) BETWEEN 1 AND 200),
    match_type TEXT NOT NULL DEFAULT 'contains'
                 CHECK (match_type IN ('contains', 'word', 'regex')),
    category   TEXT NOT NULL DEFAULT 'other'
                 CHECK (category IN ('self_harm','hate','harassment',
                                     'sexual_content','violence','privacy','other')),
    action     TEXT NOT NULL DEFAULT 'block'
                 CHECK (action IN ('flag','block','crisis')),
    is_active  BOOLEAN NOT NULL DEFAULT TRUE,
    note       TEXT,
    created_by UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_automod_rules_active
    ON public.automod_rules (is_active) WHERE is_active;

ALTER TABLE public.automod_rules ENABLE ROW LEVEL SECURITY;

-- Mobile clients read ACTIVE rules to extend the on-device classifier.
DROP POLICY IF EXISTS "automod read active" ON public.automod_rules;
CREATE POLICY "automod read active"
    ON public.automod_rules FOR SELECT TO authenticated
    USING (is_active = true);

-- Staff manage all rules (console also uses the service-role key).
DROP POLICY IF EXISTS "automod staff manage" ON public.automod_rules;
CREATE POLICY "automod staff manage"
    ON public.automod_rules FOR ALL
    USING (is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']))
    WITH CHECK (is_staff(auth.uid(), ARRAY['super_admin','admin','moderator']));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.automod_rules TO authenticated;

-- =========================================================================
-- 4) Per-user report history (reports filed against this user's content)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.admin_user_report_history(
    p_user  UUID,
    p_limit INT DEFAULT 100
) RETURNS TABLE (
    report_id   UUID,
    reason      TEXT,
    note        TEXT,
    is_resolved BOOLEAN,
    target_kind TEXT,
    preview     TEXT,
    created_at  TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT is_staff(auth.uid(),
            ARRAY['super_admin','admin','moderator','support']) THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    RETURN QUERY
    SELECT r.report_id, r.reason, r.note, r.is_resolved,
           CASE
             WHEN r.post_id                 IS NOT NULL THEN 'post'
             WHEN r.target_tribe_message_id IS NOT NULL THEN 'tribe_message'
             WHEN r.target_chat_message_id  IS NOT NULL THEN 'dm'
             WHEN r.target_comment_id       IS NOT NULL THEN 'comment'
             ELSE 'other'
           END AS target_kind,
           COALESCE(left(p.content, 160), left(tm.content, 160),
                    CASE WHEN r.target_chat_message_id IS NOT NULL
                         THEN '(private DM — server-readable for safety review)' END,
                    '(content)') AS preview,
           r.created_at
      FROM reports r
      LEFT JOIN posts p           ON p.post_id     = r.post_id
      LEFT JOIN tribe_messages tm ON tm.message_id = r.target_tribe_message_id
      LEFT JOIN chat_messages cm  ON cm.message_id = r.target_chat_message_id
      LEFT JOIN posts_comments pc ON pc.comment_id = r.target_comment_id
     WHERE p.author_id  = p_user
        OR tm.sender_id = p_user
        OR cm.sender_id = p_user
        OR pc.author_id = p_user
     ORDER BY r.created_at DESC
     LIMIT greatest(1, p_limit);
END $$;

GRANT EXECUTE ON FUNCTION public.admin_user_report_history(UUID, INT) TO authenticated;

NOTIFY pgrst, 'reload schema';
