-- Restore Story-only activity and reply RPCs after Stories were separated
-- from audio Whispers. These functions must authorize posts.is_story rows.

CREATE OR REPLACE FUNCTION public.can_reply_to_story(
  p_post_id UUID
) RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.posts AS p
      JOIN public.users AS u ON u.user_id = p.author_id
     WHERE p.post_id = p_post_id
       AND p.is_story = TRUE
       AND p.deleted_at IS NULL
       AND p.created_at > now() - INTERVAL '24 hours'
       AND p.author_id IS DISTINCT FROM (SELECT auth.uid())
       AND u.story_replies_enabled = TRUE
  );
$$;

CREATE OR REPLACE FUNCTION public.reply_to_story(
  p_post_id UUID,
  p_reply TEXT
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_author UUID;
  v_replies_enabled BOOLEAN;
  v_room_id UUID;
  v_reply TEXT := btrim(COALESCE(p_reply, ''));
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;
  IF char_length(v_reply) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'story reply must be between 1 and 2000 characters';
  END IF;

  SELECT p.author_id, u.story_replies_enabled
    INTO v_author, v_replies_enabled
    FROM public.posts AS p
    JOIN public.users AS u ON u.user_id = p.author_id
   WHERE p.post_id = p_post_id
     AND p.is_story = TRUE
     AND p.deleted_at IS NULL
     AND p.created_at > now() - INTERVAL '24 hours';

  IF NOT FOUND OR v_author IS NULL THEN
    RAISE EXCEPTION 'story not found or expired';
  END IF;
  IF v_author = v_me THEN
    RAISE EXCEPTION 'cannot reply to your own story';
  END IF;
  IF NOT v_replies_enabled THEN
    RAISE EXCEPTION 'story replies are disabled';
  END IF;
  IF NOT public.can_dm(v_author) THEN
    RAISE EXCEPTION 'DM blocked: send a friend request first';
  END IF;

  SELECT started.room_id
    INTO v_room_id
    FROM public.start_chat_room(
      v_author,
      left('Replied to your story: ' || v_reply, 280),
      p_post_id
    ) AS started
   LIMIT 1;

  IF v_room_id IS NULL THEN
    RAISE EXCEPTION 'could not open story conversation';
  END IF;

  PERFORM 1
    FROM public.send_chat_message(
      v_room_id,
      v_reply,
      p_post_id,
      NULL,
      NULL
    );

  RETURN v_room_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.story_reactions_for_owner(
  p_post_id UUID
) RETURNS TABLE (
  user_id UUID,
  pseudonym TEXT,
  avatar_seed TEXT,
  profile_photo_url TEXT,
  is_verified BOOLEAN,
  reaction_type TEXT,
  reacted_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM public.posts AS p
     WHERE p.post_id = p_post_id
       AND p.author_id = v_me
       AND p.is_story = TRUE
       AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'story not found or not owned by caller';
  END IF;

  RETURN QUERY
  SELECT
    u.user_id,
    u.anonymous_pseudonym::TEXT,
    u.avatar_seed::TEXT,
    u.profile_photo_url::TEXT,
    u.is_verified,
    pl.reaction_type::TEXT,
    pl.created_at
  FROM public.post_likes AS pl
  JOIN public.users AS u ON u.user_id = pl.user_id
  WHERE pl.post_id = p_post_id
  ORDER BY pl.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.can_reply_to_story(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reply_to_story(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.story_reactions_for_owner(UUID)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.can_reply_to_story(UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.reply_to_story(UUID, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.story_reactions_for_owner(UUID)
  TO authenticated;
