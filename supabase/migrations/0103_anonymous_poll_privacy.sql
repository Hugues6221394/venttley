-- 0103_anonymous_poll_privacy.sql
-- "Anonymous votes" must mean OTHER members can never see WHO voted for what —
-- only the aggregate counts. Before this, the votes RLS let any tribe member
-- SELECT every raw vote row (user_id + option_id), so anonymity was UI-only.
--
-- Fix:
--   1) A SECURITY DEFINER counts function returns ONLY aggregate counts (never
--      a user_id) — safe to expose for any poll, anonymous or not.
--   2) Raw-vote RLS is tightened: you always see your OWN vote (needed to show
--      "you voted X"), but you can only see OTHER people's raw votes on a
--      NON-anonymous poll.
--   3) The feed view (security_invoker) computes counts via the definer
--      function so anonymous-poll tallies stay correct even though the raw rows
--      are now hidden.

-- 1) Aggregate-only counts, bypassing row RLS. Never returns identities.
CREATE OR REPLACE FUNCTION public.tribe_poll_option_counts(p_message_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT COALESCE(jsonb_object_agg(s.option_id, s.cnt), '{}'::jsonb)
      FROM (
        SELECT option_id, COUNT(*)::INT AS cnt
          FROM tribe_message_poll_votes
         WHERE message_id = p_message_id
         GROUP BY option_id
      ) s;
$$;
GRANT EXECUTE ON FUNCTION public.tribe_poll_option_counts(UUID) TO authenticated;

-- 2) Tighten raw-vote visibility.
DROP POLICY IF EXISTS "poll votes member read" ON public.tribe_message_poll_votes;
DROP POLICY IF EXISTS "poll votes read" ON public.tribe_message_poll_votes;
CREATE POLICY "poll votes read"
  ON public.tribe_message_poll_votes FOR SELECT
  USING (
    -- Always your own vote.
    user_id = auth.uid()
    OR EXISTS (
      -- Others' raw votes only on a NON-anonymous poll (still tribe-scoped).
      SELECT 1
        FROM public.tribe_messages m
        JOIN public.tribe_members tm ON tm.tribe_id = m.tribe_id
       WHERE m.message_id = tribe_message_poll_votes.message_id
         AND tm.user_id = auth.uid()
         AND COALESCE((m.metadata->>'anonymous_votes')::boolean, false) = false
    )
  );

-- 3) Recreate the feed view, swapping the inline count subquery for the
--    definer function (everything else identical to migration 0066).
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

NOTIFY pgrst, 'reload schema';
