-- 0066_tribe_chat_social.sql
-- Poll v2, emoji reactions, question reply counts, daily keeper check-in ritual.

-- =========================================================================
-- 1) Emoji reactions (one per user per message; hug stays separate)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.tribe_message_reactions (
  message_id UUID NOT NULL REFERENCES public.tribe_messages(message_id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  emoji      TEXT NOT NULL CHECK (emoji IN ('same', 'proud', 'tea', 'heart')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS tribe_message_reactions_message_idx
  ON public.tribe_message_reactions (message_id);

ALTER TABLE public.tribe_message_reactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tribe reactions member read" ON public.tribe_message_reactions;
CREATE POLICY "tribe reactions member read"
  ON public.tribe_message_reactions FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.tribe_messages m
      JOIN public.tribe_members tm ON tm.tribe_id = m.tribe_id
       WHERE m.message_id = tribe_message_reactions.message_id
         AND tm.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "tribe reactions own write" ON public.tribe_message_reactions;
CREATE POLICY "tribe reactions own write"
  ON public.tribe_message_reactions FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.tribe_message_reactions TO authenticated;

CREATE OR REPLACE FUNCTION public.set_tribe_message_reaction(
    p_message_id UUID,
    p_emoji      TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_tribe_id UUID;
    v_existing TEXT;
    v_counts JSONB;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_emoji NOT IN ('same', 'proud', 'tea', 'heart') THEN
        RAISE EXCEPTION 'invalid emoji';
    END IF;

    SELECT m.tribe_id INTO v_tribe_id
      FROM public.tribe_messages m
     WHERE m.message_id = p_message_id AND m.deleted_at IS NULL;
    IF v_tribe_id IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.tribe_members
         WHERE tribe_id = v_tribe_id AND user_id = v_me
    ) THEN
        RAISE EXCEPTION 'not a tribe member';
    END IF;

    SELECT emoji INTO v_existing
      FROM public.tribe_message_reactions
     WHERE message_id = p_message_id AND user_id = v_me;

    IF v_existing = p_emoji THEN
        DELETE FROM public.tribe_message_reactions
         WHERE message_id = p_message_id AND user_id = v_me;
        v_existing := NULL;
    ELSE
        INSERT INTO public.tribe_message_reactions (message_id, user_id, emoji)
        VALUES (p_message_id, v_me, p_emoji)
        ON CONFLICT (message_id, user_id)
        DO UPDATE SET emoji = EXCLUDED.emoji, created_at = now();
        v_existing := p_emoji;
    END IF;

    SELECT COALESCE(jsonb_object_agg(emoji, cnt), '{}'::jsonb)
      INTO v_counts
      FROM (
        SELECT emoji, COUNT(*)::INT AS cnt
          FROM public.tribe_message_reactions
         WHERE message_id = p_message_id
         GROUP BY emoji
      ) s;

    RETURN jsonb_build_object('my_reaction', v_existing, 'reaction_counts', v_counts);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_tribe_message_reaction(UUID, TEXT) TO authenticated;

-- =========================================================================
-- 2) Poll v2 — close poll (keeper/co-mod), up to 4 options
-- =========================================================================
CREATE OR REPLACE FUNCTION public.close_tribe_chat_poll(p_message_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_tribe_id UUID;
    v_meta JSONB;
    v_can BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    SELECT m.tribe_id, m.metadata
      INTO v_tribe_id, v_meta
      FROM public.tribe_messages m
     WHERE m.message_id = p_message_id AND m.deleted_at IS NULL;

    IF v_tribe_id IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF COALESCE(v_meta->>'kind', '') <> 'poll' THEN
        RAISE EXCEPTION 'not a poll message';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.tribes t
         WHERE t.tribe_id = v_tribe_id AND t.keeper_id = v_me
    ) OR EXISTS (
        SELECT 1 FROM public.tribe_members tm
         WHERE tm.tribe_id = v_tribe_id AND tm.user_id = v_me
           AND tm.role IN ('keeper', 'co_mod')
    ) INTO v_can;

    IF NOT v_can THEN RAISE EXCEPTION 'not authorized'; END IF;

    UPDATE public.tribe_messages
       SET metadata = COALESCE(metadata, '{}'::jsonb)
           || jsonb_build_object('is_closed', true, 'closed_at', now())
     WHERE message_id = p_message_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.close_tribe_chat_poll(UUID) TO authenticated;

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
      FROM public.tribe_messages m
     WHERE m.message_id = p_message_id AND m.deleted_at IS NULL;

    IF v_tribe_id IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
    IF COALESCE(v_meta->>'kind', '') <> 'poll' THEN
        RAISE EXCEPTION 'not a poll message';
    END IF;
    IF COALESCE(v_meta->>'is_closed', 'false') = 'true' THEN
        RAISE EXCEPTION 'poll is closed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.tribe_members
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
        SELECT 1 FROM public.tribe_message_poll_votes
         WHERE message_id = p_message_id AND user_id = v_me
    ) THEN
        RAISE EXCEPTION 'already voted';
    END IF;

    INSERT INTO public.tribe_message_poll_votes (message_id, user_id, option_id)
    VALUES (p_message_id, v_me, p_option_id);

    SELECT COALESCE(jsonb_object_agg(option_id, cnt), '{}'::jsonb)
      INTO v_counts
      FROM (
        SELECT option_id, COUNT(*)::INT AS cnt
          FROM public.tribe_message_poll_votes
         WHERE message_id = p_message_id
         GROUP BY option_id
      ) s;

    RETURN jsonb_build_object(
        'my_vote_option_id', p_option_id,
        'option_counts', v_counts
    );
END;
$$;

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
    v_opt_len INT;
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
            v_opt_len := jsonb_array_length(COALESCE(p_metadata->'options', '[]'::jsonb));
            IF v_opt_len < 2 OR v_opt_len > 4 THEN
                RAISE EXCEPTION 'poll needs 2–4 options';
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

-- =========================================================================
-- 3) Daily keeper check-in ritual (pg_cron, hourly tick)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.run_tribe_daily_checkins()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tribe RECORD;
    v_hour INT := EXTRACT(HOUR FROM (now() AT TIME ZONE 'UTC'));
    v_today TEXT := to_char((now() AT TIME ZONE 'UTC')::date, 'YYYY-MM-DD');
    v_count INT := 0;
    v_prompt TEXT;
BEGIN
    FOR v_tribe IN
        SELECT t.tribe_id, t.keeper_id, t.chat_settings
          FROM public.tribes t
         WHERE t.keeper_id IS NOT NULL
           AND COALESCE((t.chat_settings->>'daily_checkin_enabled')::boolean, false) = true
           AND COALESCE((t.chat_settings->>'daily_checkin_hour')::int, 13) = v_hour
           AND COALESCE(t.chat_settings->>'daily_checkin_last_run', '') <> v_today
         FOR UPDATE OF t SKIP LOCKED
    LOOP
        v_prompt := COALESCE(
            NULLIF(trim(v_tribe.chat_settings->>'daily_checkin_prompt'), ''),
            'How is everyone feeling today?'
        );

        INSERT INTO public.tribe_messages (tribe_id, sender_id, metadata)
        VALUES (
            v_tribe.tribe_id,
            v_tribe.keeper_id,
            jsonb_build_object(
                'kind', 'question',
                'prompt', v_prompt,
                'auto_checkin', true
            )
        );

        UPDATE public.tribes
           SET chat_settings = COALESCE(chat_settings, '{}'::jsonb)
               || jsonb_build_object('daily_checkin_last_run', v_today)
         WHERE tribe_id = v_tribe.tribe_id;

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;

DO $$
DECLARE
    v_existing INT;
BEGIN
    SELECT jobid INTO v_existing
      FROM cron.job
     WHERE jobname = 'tribe_daily_checkins_hourly';
    IF v_existing IS NOT NULL THEN
        PERFORM cron.unschedule(v_existing);
    END IF;
    PERFORM cron.schedule(
        'tribe_daily_checkins_hourly',
        '0 * * * *',
        $cron$ SELECT public.run_tribe_daily_checkins(); $cron$
    );
END $$;

-- =========================================================================
-- 4) Feed view — reactions + question reply counts
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
    ) AS poll_option_counts,
    (
        SELECT r.emoji
          FROM tribe_message_reactions r
         WHERE r.message_id = m.message_id AND r.user_id = auth.uid()
    ) AS my_reaction,
    (
        SELECT COALESCE(jsonb_object_agg(s.emoji, s.cnt), '{}'::jsonb)
          FROM (
            SELECT emoji, COUNT(*)::INT AS cnt
              FROM tribe_message_reactions
             WHERE message_id = m.message_id
             GROUP BY emoji
          ) s
    ) AS reaction_counts,
    (
        SELECT COUNT(*)::INT
          FROM tribe_messages q
         WHERE q.reply_to_message_id = m.message_id
           AND q.deleted_at IS NULL
    ) AS question_reply_count
FROM public.tribe_messages m
JOIN public.tribes t ON t.tribe_id = m.tribe_id
LEFT JOIN public.users    u   ON u.user_id     = m.sender_id
LEFT JOIN public.personas pr  ON pr.persona_id = m.sender_persona_id
                              AND pr.deleted_at IS NULL
LEFT JOIN public.tribe_messages rm ON rm.message_id = m.reply_to_message_id
LEFT JOIN public.users ru ON ru.user_id = rm.sender_id
LEFT JOIN public.personas rpr ON rpr.persona_id = rm.sender_persona_id;

GRANT SELECT ON public.tribe_messages_feed TO authenticated;
