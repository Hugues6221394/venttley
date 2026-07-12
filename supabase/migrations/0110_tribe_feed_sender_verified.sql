-- 0110_tribe_feed_sender_verified.sql
-- Surface the sender's verification status in the tribe chat feed so a verified
-- member's ✓ tick can render next to their name on every message.
--
-- Persona-sent messages deliberately return false: a persona is an alias, and
-- showing the underlying account's verified badge would de-anonymize it.
--
-- This is a straight re-create of the migration 0103 view with one added
-- column (sender_is_verified); everything else is identical.

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
    CASE WHEN m.sender_persona_id IS NULL THEN COALESCE(u.is_verified, false) ELSE false END
                                                                AS sender_is_verified,
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
    public.tribe_poll_option_counts(m.message_id) AS poll_option_counts,
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
