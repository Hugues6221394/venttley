-- Make the existing DM voice-note client path valid and keep every DM send
-- behind one canonical membership/status/media validation function.

ALTER TABLE public.chat_messages
  DROP CONSTRAINT IF EXISTS chat_messages_attached_media_type_check;
ALTER TABLE public.chat_messages
  ADD CONSTRAINT chat_messages_attached_media_type_check
  CHECK (
    attached_media_type IS NULL
    OR attached_media_type IN ('image', 'audio')
  );

UPDATE storage.buckets
   SET allowed_mime_types = ARRAY[
     'image/jpeg',
     'image/png',
     'image/webp',
     'image/heic',
     'image/gif',
     'audio/mp4',
     'audio/aac',
     'audio/mpeg',
     'audio/ogg',
     'audio/webm',
     'audio/x-m4a'
   ]
 WHERE id = 'chat-media';

CREATE OR REPLACE FUNCTION public.send_chat_message(
  p_room_id UUID,
  p_payload TEXT,
  p_attached_post_id UUID DEFAULT NULL,
  p_media_path TEXT DEFAULT NULL,
  p_media_type TEXT DEFAULT NULL
) RETURNS TABLE (
  message_id UUID,
  room_id UUID,
  sender_id UUID,
  payload TEXT,
  attached_post_id UUID,
  attached_post_snapshot JSONB,
  attached_media_path TEXT,
  attached_media_type TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_room public.chat_rooms%ROWTYPE;
  v_snapshot JSONB;
  v_row public.chat_messages%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT *
    INTO v_room
    FROM public.chat_rooms r
   WHERE r.room_id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'room not found';
  END IF;
  IF v_me IS DISTINCT FROM v_room.initiated_by
     AND v_me IS DISTINCT FROM v_room.received_by THEN
    RAISE EXCEPTION 'not a participant';
  END IF;
  IF v_room.room_status <> 'active' THEN
    RAISE EXCEPTION 'room is not active';
  END IF;

  IF (p_media_path IS NULL) <> (p_media_type IS NULL) THEN
    RAISE EXCEPTION 'media path and type must be provided together';
  END IF;
  IF p_media_path IS NOT NULL
     AND p_media_path !~ ('^' || p_room_id::TEXT || '/') THEN
    RAISE EXCEPTION 'media path must be in room prefix';
  END IF;
  IF p_media_type IS NOT NULL AND p_media_type NOT IN ('image', 'audio') THEN
    RAISE EXCEPTION 'unsupported media type';
  END IF;
  IF btrim(COALESCE(p_payload, '')) = ''
     AND p_attached_post_id IS NULL
     AND p_media_path IS NULL THEN
    RAISE EXCEPTION 'message must have content or an attachment';
  END IF;

  IF p_attached_post_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'post_id', p.post_id,
      'content', left(p.content, 400),
      'author_id', p.author_id,
      'category', p.category_name,
      'mood', p.post_mood,
      'is_whisper', p.is_whisper,
      'created_at', p.created_at,
      'author_pseudonym',
        COALESCE('@' || pr.pseudonym, '@' || u.anonymous_pseudonym),
      'author_avatar_seed',
        COALESCE(pr.avatar_seed, u.avatar_seed)
    )
      INTO v_snapshot
      FROM public.posts p
      LEFT JOIN public.users u ON u.user_id = p.author_id
      LEFT JOIN public.personas pr
        ON pr.persona_id = p.persona_id
       AND pr.deleted_at IS NULL
     WHERE p.post_id = p_attached_post_id
       AND p.deleted_at IS NULL
       AND (
         p.tribe_id IS NULL
         OR NOT EXISTS (
           SELECT 1
             FROM public.tribes t
            WHERE t.tribe_id = p.tribe_id
              AND t.is_private
         )
         OR EXISTS (
           SELECT 1
             FROM public.tribe_members tm
            WHERE tm.tribe_id = p.tribe_id
              AND tm.user_id = v_me
         )
       );
    IF v_snapshot IS NULL THEN
      RAISE EXCEPTION 'attached post not found or not readable';
    END IF;
  END IF;

  INSERT INTO public.chat_messages (
    room_id,
    sender_id,
    encrypted_payload,
    nonce_iv,
    attached_post_id,
    attached_post_snapshot,
    attached_media_path,
    attached_media_type
  ) VALUES (
    p_room_id,
    v_me,
    COALESCE(p_payload, ''),
    'v1-plaintext',
    p_attached_post_id,
    v_snapshot,
    p_media_path,
    p_media_type
  ) RETURNING * INTO v_row;

  message_id := v_row.message_id;
  room_id := v_row.room_id;
  sender_id := v_row.sender_id;
  payload := v_row.encrypted_payload;
  attached_post_id := v_row.attached_post_id;
  attached_post_snapshot := v_row.attached_post_snapshot;
  attached_media_path := v_row.attached_media_path;
  attached_media_type := v_row.attached_media_type;
  created_at := v_row.created_at;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.send_chat_message(
  UUID, TEXT, UUID, TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_chat_message(
  UUID, TEXT, UUID, TEXT, TEXT
) TO authenticated;

NOTIFY pgrst, 'reload schema';
