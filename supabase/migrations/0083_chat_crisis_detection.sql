-- 0083_chat_crisis_detection.sql
-- Extend crisis detection from posts/whispers to CHAT. A member confessing
-- suicidal ideation in a tribe hub or DM should reach the Safety queue and be
-- shown help immediately — not only if a peer happens to report them.
--
-- Historical note: the column is named encrypted_payload, but the current
-- product stores server-readable plaintext for moderation. Migration
-- 20260811222118 adds an authoritative database safety trigger; the author-only
-- RPCs below remain compatible with older clients.
--
-- Also folds crisis-flagged messages into admin_safety_queue() (0082).

-- 1) crisis_level columns (same domain as posts.crisis_level, migration 0020).
ALTER TABLE public.tribe_messages
    ADD COLUMN IF NOT EXISTS crisis_level TEXT
    CHECK (crisis_level IS NULL OR crisis_level IN ('elevated', 'high'));
ALTER TABLE public.chat_messages
    ADD COLUMN IF NOT EXISTS crisis_level TEXT
    CHECK (crisis_level IS NULL OR crisis_level IN ('elevated', 'high'));

CREATE INDEX IF NOT EXISTS tribe_messages_crisis_idx
    ON public.tribe_messages (crisis_level, created_at DESC)
    WHERE crisis_level IS NOT NULL;
CREATE INDEX IF NOT EXISTS chat_messages_crisis_idx
    ON public.chat_messages (crisis_level, created_at DESC)
    WHERE crisis_level IS NOT NULL;

-- 2) Author-only taggers (mirror set_post_crisis).
CREATE OR REPLACE FUNCTION public.set_tribe_message_crisis(
    p_message_id UUID,
    p_level      TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_sender UUID;
BEGIN
    IF p_level IS NOT NULL AND p_level NOT IN ('elevated', 'high') THEN
        RAISE EXCEPTION 'invalid crisis level: %', p_level;
    END IF;
    SELECT sender_id INTO v_sender FROM tribe_messages WHERE message_id = p_message_id;
    IF v_sender IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF v_sender <> auth.uid() THEN RAISE EXCEPTION 'only the sender can tag a message'; END IF;
    UPDATE tribe_messages SET crisis_level = p_level WHERE message_id = p_message_id;
END $$;

REVOKE ALL ON FUNCTION public.set_tribe_message_crisis(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_tribe_message_crisis(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_chat_message_crisis(
    p_message_id UUID,
    p_level      TEXT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_sender UUID;
BEGIN
    IF p_level IS NOT NULL AND p_level NOT IN ('elevated', 'high') THEN
        RAISE EXCEPTION 'invalid crisis level: %', p_level;
    END IF;
    SELECT sender_id INTO v_sender FROM chat_messages WHERE message_id = p_message_id;
    IF v_sender IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF v_sender <> auth.uid() THEN RAISE EXCEPTION 'only the sender can tag a message'; END IF;
    UPDATE chat_messages SET crisis_level = p_level WHERE message_id = p_message_id;
END $$;

REVOKE ALL ON FUNCTION public.set_chat_message_crisis(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_chat_message_crisis(UUID, TEXT) TO authenticated;

-- 3) Fold crisis-flagged messages into the safety queue (re-declares 0082's
--    function with two extra UNION branches).
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
    WITH items (
        item_type, severity, severity_rank, ref_id, report_id, reason, note,
        author_id, author_pseudonym, preview, is_open, created_at
    ) AS (
        SELECT 'crisis_post'::TEXT, p.crisis_level,
               CASE p.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
               p.post_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
               p.author_id, u.anonymous_pseudonym,
               left(coalesce(p.content, ''), 200), (p.deleted_at IS NULL),
               p.created_at
          FROM public.posts p
          LEFT JOIN public.users u ON u.user_id = p.author_id
         WHERE p.crisis_level IS NOT NULL

        UNION ALL
        SELECT 'crisis_whisper', w.crisis_level,
               CASE w.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
               w.whisper_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
               w.author_id, u.anonymous_pseudonym,
               left(coalesce(w.title, w.description, 'Voice whisper'), 200),
               (w.deleted_at IS NULL), w.created_at
          FROM public.whispers w
          LEFT JOIN public.users u ON u.user_id = w.author_id
         WHERE w.crisis_level IS NOT NULL

        UNION ALL
        SELECT 'crisis_tribe_message', tm.crisis_level,
               CASE tm.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
               tm.message_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
               tm.sender_id, u.anonymous_pseudonym,
               left(coalesce(tm.content, ''), 200), (tm.deleted_at IS NULL),
               tm.created_at
          FROM public.tribe_messages tm
          LEFT JOIN public.users u ON u.user_id = tm.sender_id
         WHERE tm.crisis_level IS NOT NULL

        UNION ALL
        SELECT 'crisis_dm', cm.crisis_level,
               CASE cm.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
               cm.message_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
               cm.sender_id, u.anonymous_pseudonym,
               '(private DM — server-readable; access restricted)', TRUE,
               cm.created_at
          FROM public.chat_messages cm
          LEFT JOIN public.users u ON u.user_id = cm.sender_id
         WHERE cm.crisis_level IS NOT NULL

        UNION ALL
        SELECT 'self_harm_report', 'high', 3,
               r.report_id, r.report_id, r.reason, r.note,
               COALESCE(p.author_id, tm.sender_id, cm.sender_id),
               COALESCE(pu.anonymous_pseudonym, tmu.anonymous_pseudonym,
                        cmu.anonymous_pseudonym),
               COALESCE(
                   left(p.content, 200),
                   left(tm.content, 200),
                   CASE WHEN r.target_chat_message_id IS NOT NULL
                        THEN '(private DM — server-readable; access restricted)' END,
                   CASE WHEN r.target_comment_id IS NOT NULL THEN '(reported comment)' END,
                   CASE WHEN r.target_room_id    IS NOT NULL THEN '(reported conversation)' END,
                   '(reported content)'
               ),
               (NOT r.is_resolved), r.created_at
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

NOTIFY pgrst, 'reload schema';
