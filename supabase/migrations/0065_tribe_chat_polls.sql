-- 0065_tribe_chat_polls.sql
-- Rich in-chat poll cards: metadata on tribe_messages + vote table.

ALTER TABLE public.tribe_messages
  ADD COLUMN IF NOT EXISTS metadata JSONB;

CREATE TABLE IF NOT EXISTS public.tribe_message_poll_votes (
  message_id UUID NOT NULL REFERENCES public.tribe_messages(message_id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  option_id  TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS tribe_message_poll_votes_message_idx
  ON public.tribe_message_poll_votes (message_id);

ALTER TABLE public.tribe_message_poll_votes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "poll votes member read" ON public.tribe_message_poll_votes;
CREATE POLICY "poll votes member read"
  ON public.tribe_message_poll_votes FOR SELECT
  USING (
    EXISTS (
      SELECT 1
        FROM public.tribe_messages m
        JOIN public.tribe_members tm ON tm.tribe_id = m.tribe_id
       WHERE m.message_id = tribe_message_poll_votes.message_id
         AND tm.user_id = auth.uid()
    )
  );

-- =========================================================================
-- send_tribe_message — metadata (poll / question cards)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.send_tribe_message(
    p_tribe_id               UUID,
    p_content                TEXT  DEFAULT NULL,
    p_persona_id             UUID  DEFAULT NULL,
    p_image_url              TEXT  DEFAULT NULL,
    p_image_path             TEXT  DEFAULT NULL,
    p_audio_url              TEXT  DEFAULT NULL,
    p_audio_path             TEXT  DEFAULT NULL,
    p_audio_duration_seconds INT   DEFAULT NULL,
    p_reply_to_message_id    UUID  DEFAULT NULL,
    p_metadata               JSONB DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_is_member BOOLEAN;
    v_msg_id UUID;
    v_kind TEXT;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT EXISTS (
        SELECT 1 FROM tribe_members
         WHERE tribe_id = p_tribe_id AND user_id = v_me
    ) INTO v_is_member;
    IF NOT v_is_member THEN RAISE EXCEPTION 'not a tribe member'; END IF;

    IF p_content IS NULL AND p_image_url IS NULL AND p_audio_url IS NULL
       AND p_metadata IS NULL THEN
        RAISE EXCEPTION 'message must have content, media, or metadata';
    END IF;

    IF p_metadata IS NOT NULL THEN
        v_kind := p_metadata->>'kind';
        IF v_kind = 'poll' THEN
            IF COALESCE(trim(p_metadata->>'question'), '') = '' THEN
                RAISE EXCEPTION 'poll needs a question';
            END IF;
            IF jsonb_array_length(COALESCE(p_metadata->'options', '[]'::jsonb)) < 2 THEN
                RAISE EXCEPTION 'poll needs at least 2 options';
            END IF;
        ELSIF v_kind = 'question' THEN
            IF COALESCE(trim(p_metadata->>'prompt'), '') = '' THEN
                RAISE EXCEPTION 'question needs a prompt';
            END IF;
        END IF;
    END IF;

    IF p_reply_to_message_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM tribe_messages
             WHERE message_id = p_reply_to_message_id
               AND tribe_id = p_tribe_id
               AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'reply target not found';
        END IF;
    END IF;

    INSERT INTO tribe_messages (
        tribe_id, sender_id, sender_persona_id,
        content, image_url, image_path,
        audio_url, audio_path, audio_duration_seconds,
        reply_to_message_id, metadata
    ) VALUES (
        p_tribe_id, v_me, p_persona_id,
        p_content, p_image_url, p_image_path,
        p_audio_url, p_audio_path, p_audio_duration_seconds,
        p_reply_to_message_id, p_metadata
    ) RETURNING message_id INTO v_msg_id;

    UPDATE tribe_members
       SET last_read_at = now()
     WHERE tribe_id = p_tribe_id AND user_id = v_me;

    RETURN v_msg_id;
END $$;

GRANT EXECUTE ON FUNCTION public.send_tribe_message(
    UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, INT, UUID, JSONB
) TO authenticated;

-- =========================================================================
-- vote_tribe_chat_poll
-- =========================================================================
CREATE OR REPLACE FUNCTION public.vote_tribe_chat_poll(
    p_message_id UUID,
    p_option_id  TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_tribe_id UUID;
    v_meta JSONB;
    v_found BOOLEAN := false;
    v_opt JSONB;
    v_counts JSONB;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT m.tribe_id, m.metadata
      INTO v_tribe_id, v_meta
      FROM tribe_messages m
     WHERE m.message_id = p_message_id
       AND m.deleted_at IS NULL;

    IF v_tribe_id IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF COALESCE(v_meta->>'kind', '') <> 'poll' THEN
        RAISE EXCEPTION 'not a poll message';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM tribe_members
         WHERE tribe_id = v_tribe_id AND user_id = v_me
    ) THEN
        RAISE EXCEPTION 'not a tribe member';
    END IF;

    FOR v_opt IN SELECT * FROM jsonb_array_elements(v_meta->'options')
    LOOP
        IF v_opt->>'id' = p_option_id THEN
            v_found := true;
            EXIT;
        END IF;
    END LOOP;
    IF NOT v_found THEN RAISE EXCEPTION 'invalid option'; END IF;

    IF EXISTS (
        SELECT 1 FROM tribe_message_poll_votes
         WHERE message_id = p_message_id AND user_id = v_me
    ) THEN
        RAISE EXCEPTION 'already voted';
    END IF;

    INSERT INTO tribe_message_poll_votes (message_id, user_id, option_id)
    VALUES (p_message_id, v_me, p_option_id);

    SELECT COALESCE(
        jsonb_object_agg(option_id, cnt),
        '{}'::jsonb
    )
      INTO v_counts
      FROM (
        SELECT option_id, COUNT(*)::INT AS cnt
          FROM tribe_message_poll_votes
         WHERE message_id = p_message_id
         GROUP BY option_id
      ) s;

    RETURN jsonb_build_object(
        'my_vote_option_id', p_option_id,
        'option_counts', v_counts
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.vote_tribe_chat_poll(UUID, TEXT) TO authenticated;

-- =========================================================================
-- Feed view — metadata + poll aggregates
-- New columns must be appended (Postgres rejects mid-list INSERT on REPLACE).
-- =========================================================================
DROP VIEW IF EXISTS public.tribe_messages_feed;

CREATE VIEW public.tribe_messages_feed
WITH (security_invoker = true) AS
SELECT
    m.message_id,
    m.tribe_id,
    m.sender_id,
    COALESCE(pr.pseudonym, u.anonymous_pseudonym, 'anonymous') AS sender_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb')      AS sender_avatar_seed,
    CASE WHEN m.sender_persona_id IS NULL THEN u.profile_photo_url ELSE NULL END
                                                                AS sender_profile_photo_url,
    m.sender_persona_id,
    m.content,
    m.image_url,
    m.audio_url,
    m.audio_duration_seconds,
    m.hugs_count,
    m.created_at,
    m.edited_at,
    m.deleted_at,
    m.reply_to_message_id,
    rm.content AS reply_content,
    COALESCE(rpr.pseudonym, ru.anonymous_pseudonym) AS reply_sender_pseudonym,
    EXISTS (
        SELECT 1 FROM tribe_message_hugs h
         WHERE h.message_id = m.message_id AND h.user_id = auth.uid()
    ) AS hugged_by_me,
    (t.pinned_message_id = m.message_id) AS is_pinned,
    m.metadata,
    (
        SELECT pv.option_id
          FROM tribe_message_poll_votes pv
         WHERE pv.message_id = m.message_id AND pv.user_id = auth.uid()
    ) AS poll_my_vote_option_id,
    (
        SELECT COALESCE(jsonb_object_agg(s.option_id, s.cnt), '{}'::jsonb)
          FROM (
            SELECT option_id, COUNT(*)::INT AS cnt
              FROM tribe_message_poll_votes
             WHERE message_id = m.message_id
             GROUP BY option_id
          ) s
    ) AS poll_option_counts
FROM public.tribe_messages m
JOIN public.tribes t ON t.tribe_id = m.tribe_id
LEFT JOIN public.users    u   ON u.user_id     = m.sender_id
LEFT JOIN public.personas pr  ON pr.persona_id = m.sender_persona_id
                              AND pr.deleted_at IS NULL
LEFT JOIN public.tribe_messages rm ON rm.message_id = m.reply_to_message_id
LEFT JOIN public.users ru ON ru.user_id = rm.sender_id
LEFT JOIN public.personas rpr ON rpr.persona_id = rm.sender_persona_id;

GRANT SELECT ON public.tribe_messages_feed TO authenticated;
