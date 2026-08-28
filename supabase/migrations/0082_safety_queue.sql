-- 0082_safety_queue.sql
-- Unified Safety / Crisis queue for the admin console. Surfaces, in one
-- prioritized list, every open signal that a member may be at risk:
--   * posts flagged crisis (crisis_level elevated/high)
--   * whispers flagged crisis
--   * open self-harm *reports* (a peer flagged content), resolved to the
--     at-risk author + a content preview across every report target type
--
-- Exposed as a SECURITY DEFINER function gated by is_staff() — this is
-- suicide-risk data, so it must never be readable by a normal user, even if
-- they call the function directly. The historical encrypted_payload column
-- stores server-readable chat text; access remains limited to authorized
-- safety staff and previews must never leave this protected surface.
--
-- severity_rank drives ordering (high=3, elevated=2); ties break on recency.

CREATE OR REPLACE FUNCTION public.admin_safety_queue(
    p_include_resolved BOOLEAN DEFAULT FALSE,
    p_limit            INT     DEFAULT 200
) RETURNS TABLE (
    item_type        TEXT,
    severity         TEXT,
    severity_rank    INT,
    ref_id           UUID,
    report_id        UUID,
    reason           TEXT,
    note             TEXT,
    author_id        UUID,
    author_pseudonym TEXT,
    preview          TEXT,
    is_open          BOOLEAN,
    created_at       TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_staff(auth.uid(),
            ARRAY['super_admin','admin','moderator','support']) THEN
        RAISE EXCEPTION 'not authorized';
    END IF;

    RETURN QUERY
    WITH items AS (
        -- 1) Crisis-flagged posts
        SELECT 'crisis_post'::TEXT AS item_type,
               p.crisis_level       AS severity,
               CASE p.crisis_level WHEN 'high' THEN 3 ELSE 2 END AS severity_rank,
               p.post_id            AS ref_id,
               NULL::UUID           AS report_id,
               NULL::TEXT           AS reason,
               NULL::TEXT           AS note,
               p.author_id          AS author_id,
               u.anonymous_pseudonym AS author_pseudonym,
               left(coalesce(p.content, ''), 200) AS preview,
               (p.deleted_at IS NULL) AS is_open,
               p.created_at         AS created_at
          FROM public.posts p
          LEFT JOIN public.users u ON u.user_id = p.author_id
         WHERE p.crisis_level IS NOT NULL

        UNION ALL
        -- 2) Crisis-flagged whispers
        SELECT 'crisis_whisper',
               w.crisis_level,
               CASE w.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
               w.whisper_id,
               NULL::UUID,
               NULL::TEXT,
               NULL::TEXT,
               w.author_id,
               u.anonymous_pseudonym,
               left(coalesce(w.title, w.description, 'Voice whisper'), 200),
               (w.deleted_at IS NULL),
               w.created_at
          FROM public.whispers w
          LEFT JOIN public.users u ON u.user_id = w.author_id
         WHERE w.crisis_level IS NOT NULL

        UNION ALL
        -- 3) Open self-harm reports — resolve the at-risk author + preview
        --    across whichever target the report points at.
        SELECT 'self_harm_report',
               'high',
               3,
               r.report_id,
               r.report_id,
               r.reason,
               r.note,
               COALESCE(p.author_id, tm.sender_id, cm.sender_id) AS author_id,
               COALESCE(pu.anonymous_pseudonym, tmu.anonymous_pseudonym,
                        cmu.anonymous_pseudonym)                 AS author_pseudonym,
               COALESCE(
                   left(p.content, 200),
                   left(tm.content, 200),
                   CASE WHEN r.target_chat_message_id IS NOT NULL
                        THEN '(private DM — server-readable; access restricted)' END,
                   CASE WHEN r.target_comment_id IS NOT NULL THEN '(reported comment)' END,
                   CASE WHEN r.target_room_id    IS NOT NULL THEN '(reported conversation)' END,
                   '(reported content)'
               ) AS preview,
               (NOT r.is_resolved) AS is_open,
               r.created_at
          FROM public.reports r
          LEFT JOIN public.posts p           ON p.post_id     = r.post_id
          LEFT JOIN public.users pu          ON pu.user_id    = p.author_id
          LEFT JOIN public.tribe_messages tm ON tm.message_id = r.target_tribe_message_id
          LEFT JOIN public.users tmu         ON tmu.user_id   = tm.sender_id
          LEFT JOIN public.chat_messages cm  ON cm.message_id = r.target_chat_message_id
          LEFT JOIN public.users cmu         ON cmu.user_id   = cm.sender_id
         WHERE r.reason = 'self_harm'
    )
    SELECT * FROM items
     WHERE p_include_resolved OR items.is_open
     ORDER BY items.is_open DESC, items.severity_rank DESC, items.created_at DESC
     LIMIT greatest(1, p_limit);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_safety_queue(BOOLEAN, INT) TO authenticated;

-- Lightweight open-count for the Control Center badge / SLA alerting.
CREATE OR REPLACE FUNCTION public.admin_safety_open_count()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_n INT;
BEGIN
    IF NOT public.is_staff(auth.uid(),
            ARRAY['super_admin','admin','moderator','support']) THEN
        RAISE EXCEPTION 'not authorized';
    END IF;
    SELECT count(*) INTO v_n FROM public.admin_safety_queue(FALSE, 1000);
    RETURN COALESCE(v_n, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_safety_open_count() TO authenticated;

NOTIFY pgrst, 'reload schema';
