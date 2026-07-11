-- 0106_admin_sessions_ip.sql
-- Security visibility for super-admins: read a user's active sessions with
-- their IP + device, and make sure IPs also land on audit rows.

-- ---- Per-user sessions (IP + device), super_admin only ---------------------
-- Reads GoTrue's auth.sessions (owner = postgres, so the definer function can
-- see it). IP addresses are sensitive → super_admin gate only.
CREATE OR REPLACE FUNCTION public.admin_user_sessions(p_target UUID)
RETURNS TABLE (
    session_id UUID,
    ip         TEXT,
    user_agent TEXT,
    aal        TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    not_after  TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: super_admin only';
    END IF;
    RETURN QUERY
        SELECT s.id,
               host(s.ip)::text,
               s.user_agent,
               s.aal::text,
               s.created_at,
               s.updated_at,
               s.not_after
          FROM auth.sessions s
         WHERE s.user_id = p_target
         ORDER BY s.updated_at DESC NULLS LAST
         LIMIT 50;
END $$;
REVOKE ALL ON FUNCTION public.admin_user_sessions(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_user_sessions(UUID) TO authenticated;

-- ---- Recent distinct IPs across all users (super_admin only) ----------------
-- Powers a security overview: which IPs have active sessions, and for whom.
CREATE OR REPLACE FUNCTION public.admin_recent_ips(p_limit INT DEFAULT 100)
RETURNS TABLE (
    ip           TEXT,
    user_id      UUID,
    pseudonym    TEXT,
    last_seen    TIMESTAMPTZ,
    session_count BIGINT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
BEGIN
    IF NOT is_staff(auth.uid(), ARRAY['super_admin']) THEN
        RAISE EXCEPTION 'forbidden: super_admin only';
    END IF;
    RETURN QUERY
        SELECT host(s.ip)::text        AS ip,
               s.user_id,
               u.anonymous_pseudonym    AS pseudonym,
               max(s.updated_at)        AS last_seen,
               count(*)                 AS session_count
          FROM auth.sessions s
          LEFT JOIN public.users u ON u.user_id = s.user_id
         WHERE s.ip IS NOT NULL
         GROUP BY host(s.ip)::text, s.user_id, u.anonymous_pseudonym
         ORDER BY max(s.updated_at) DESC NULLS LAST
         LIMIT p_limit;
END $$;
REVOKE ALL ON FUNCTION public.admin_recent_ips(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_recent_ips(INT) TO authenticated;

-- ---- Copy the caller IP from metadata onto the audit row's ip column -------
-- The console's audit() helper puts the request IP in metadata.ip; surface it
-- as a first-class column so the audit view's IP field is populated.
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
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
        before_state, after_state, reason, metadata, ip
    ) VALUES (
        auth.uid(), v_pseudonym, v_role,
        p_action, p_target_type, p_target_id, p_target_label,
        p_before, p_after, p_reason, COALESCE(p_metadata, '{}'::jsonb),
        NULLIF(p_metadata->>'ip', '')
    ) RETURNING audit_id INTO v_audit_id;

    RETURN v_audit_id;
END $$;

NOTIFY pgrst, 'reload schema';
