-- 0107_profile_stats_and_verification.sql
-- (1) Profile banner stats: total posts (vents + whispers) and total hugs
--     (🫂 'hug' reactions received), exposed via a small RPC so we don't have
--     to recreate the large user_profile_summary function.
-- (2) Achievement-based verification: users auto-earn the verified check once
--     they clear positive-contribution milestones AND are in good standing.
--     Promote-only (never auto-demotes; respects manual admin verification).

-- ---- (1) Extra profile stats for the banner --------------------------------
CREATE OR REPLACE FUNCTION public.user_profile_extra_stats(p_target UUID)
RETURNS TABLE (posts_total INT, hugs_received INT, connections INT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT
        (
          (SELECT count(*) FROM posts    WHERE author_id = p_target AND deleted_at IS NULL)
          +
          (SELECT count(*) FROM whispers WHERE author_id = p_target AND deleted_at IS NULL)
        )::int AS posts_total,
        (
          SELECT count(*)::int
            FROM post_likes pl
            JOIN posts p ON p.post_id = pl.post_id
           WHERE p.author_id = p_target
             AND p.deleted_at IS NULL
             AND pl.reaction_type = 'hug'
        ) AS hugs_received,
        COALESCE((SELECT connections_count FROM users WHERE user_id = p_target), 0) AS connections;
$$;
GRANT EXECUTE ON FUNCTION public.user_profile_extra_stats(UUID) TO authenticated;

-- ---- (2) Achievement-based verification ------------------------------------
-- The verified check is a HARD-EARNED mark of a genuinely active, supportive,
-- positive member. Auto-awarded only when ALL demanding milestones are met AND
-- the account is in clean standing. It is meaningful and encouraging — most
-- users won't have it. A super_admin can always override either way (below).

-- Manual override: when a super_admin sets verification by hand, we record it
-- so the automatic sweep never fights the admin's decision.
--   NULL         = automatic (sweep may promote)
--   'manual_on'  = admin-verified   (sweep leaves it verified)
--   'manual_off' = admin-unverified (sweep will NOT re-verify)
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS verification_override TEXT
    CHECK (verification_override IN ('manual_on', 'manual_off'));

CREATE OR REPLACE FUNCTION public.evaluate_user_verification(p_user UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    -- ---- thresholds — AUTO-verify is reserved for genuinely STUNNING reach.
    -- Almost nobody hits these; everyone else APPLIES (see 0109). Tune here.
    c_min_connections CONSTANT INT := 100000;   -- 100K connections
    c_min_hugs        CONSTANT INT := 1000000;  -- 1M 🫂 received
    c_min_posts       CONSTANT INT := 25000;    -- 25K vents + whispers
    -- -----------------------------------------------------------------
    v_status   TEXT;
    v_already  BOOLEAN;
    v_override TEXT;
    v_friends  INT;
    v_posts    INT;
    v_hugs     INT;
BEGIN
    SELECT account_status, is_verified, verification_override, connections_count
      INTO v_status, v_already, v_override, v_friends
      FROM users WHERE user_id = p_user;
    IF v_status IS NULL THEN RETURN false; END IF;
    IF v_override IS NOT NULL THEN RETURN v_already; END IF;  -- admin decides
    IF v_already THEN RETURN true; END IF;                    -- promote-only

    SELECT posts_total, hugs_received INTO v_posts, v_hugs
      FROM user_profile_extra_stats(p_user);

    IF v_status = 'active'
       AND COALESCE(v_friends, 0) >= c_min_connections
       AND COALESCE(v_hugs, 0)    >= c_min_hugs
       AND COALESCE(v_posts, 0)   >= c_min_posts
    THEN
        UPDATE users SET is_verified = true, updated_at = now()
         WHERE user_id = p_user AND is_verified = false;
        BEGIN PERFORM award(p_user, 'verified'); EXCEPTION WHEN OTHERS THEN NULL; END;
        RETURN true;
    END IF;
    RETURN false;
END $$;
GRANT EXECUTE ON FUNCTION public.evaluate_user_verification(UUID) TO authenticated;

-- Batch sweep: promote every eligible, not-yet-verified, non-overridden account.
CREATE OR REPLACE FUNCTION public.sweep_user_verification()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_u UUID; v_n INT := 0;
BEGIN
    FOR v_u IN
        SELECT user_id FROM users
         WHERE is_verified = false AND account_status = 'active'
           AND verification_override IS NULL
    LOOP
        IF evaluate_user_verification(v_u) THEN v_n := v_n + 1; END IF;
    END LOOP;
    RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.sweep_user_verification() FROM PUBLIC;

-- ---- Super-admin manual verify / unverify ----------------------------------
-- Sets is_verified AND stamps verification_override so the sweep respects it.
-- p_verified NULL clears the override (back to automatic).
CREATE OR REPLACE FUNCTION public.admin_set_user_verified(
    p_target   UUID,
    p_verified BOOLEAN,
    p_reason   TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_before BOOLEAN; v_label TEXT;
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: only super_admin can set verification';
    END IF;
    SELECT is_verified, '@' || anonymous_pseudonym INTO v_before, v_label
      FROM users WHERE user_id = p_target;
    IF v_label IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;

    IF p_verified IS NULL THEN
        -- Hand control back to the automatic system.
        UPDATE users SET verification_override = NULL, updated_at = now()
         WHERE user_id = p_target;
        PERFORM evaluate_user_verification(p_target);
    ELSE
        UPDATE users
           SET is_verified = p_verified,
               verification_override = CASE WHEN p_verified THEN 'manual_on' ELSE 'manual_off' END,
               updated_at = now()
         WHERE user_id = p_target;
    END IF;

    PERFORM admin_log(
        'user.set_verified', 'user', p_target, v_label,
        jsonb_build_object('is_verified', v_before),
        jsonb_build_object('is_verified', p_verified),
        p_reason, '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.admin_set_user_verified(UUID, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_user_verified(UUID, BOOLEAN, TEXT) TO authenticated;

-- A 'verified' achievement badge (idempotent).
INSERT INTO public.badge_definitions(badge_key, label, description, icon, tier)
VALUES ('verified', 'Verified', 'Earned the verified check through community milestones.', '✅', 'gold')
ON CONFLICT (badge_key) DO NOTHING;

-- Run the sweep hourly (pg_cron). Safe + idempotent (promote-only).
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.unschedule('sweep_user_verification')
          WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sweep_user_verification');
        PERFORM cron.schedule('sweep_user_verification', '7 * * * *',
                              'SELECT public.sweep_user_verification()');
    END IF;
END $$;

-- One-time initial sweep so existing qualifying members get verified now.
SELECT public.sweep_user_verification();

NOTIFY pgrst, 'reload schema';
