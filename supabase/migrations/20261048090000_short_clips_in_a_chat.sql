-- A short clip, sent to a friend.
--
-- Chat has carried photos since 0033 and voice notes since 0097. Video has
-- never existed anywhere in the app — not in chat, not in stories, not in
-- whispers, not in posts. Adding it means saying 'video' in four places that
-- each currently enumerate exactly two types, and every one of them fails
-- closed, so missing one produces a different error rather than a silent gap.

-- 1. The bucket will take it.
--
-- chat-media is private and capped at 8 MB, which is ten or fifteen seconds of
-- passable 720p — tight enough that most clips would fail at the storage
-- boundary with an error nobody can act on. 24 MB carries about a minute.
--
-- video/quicktime as well as video/mp4 because an iPhone hands you a .mov and
-- the app is not transcoding: ffmpeg_kit_flutter_new_audio is the audio-only
-- build and ships no video codecs at all.
UPDATE storage.buckets
   SET allowed_mime_types = ARRAY[
         'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/gif',
         'audio/mp4', 'audio/aac', 'audio/mpeg', 'audio/ogg', 'audio/webm',
         'audio/x-m4a',
         'video/mp4', 'video/quicktime'
       ],
       file_size_limit = 25165824
 WHERE id = 'chat-media';

-- 2. The row will hold it.
ALTER TABLE public.chat_messages
  DROP CONSTRAINT IF EXISTS chat_messages_attached_media_type_check;
ALTER TABLE public.chat_messages
  ADD CONSTRAINT chat_messages_attached_media_type_check
  CHECK (
    attached_media_type IS NULL
    OR attached_media_type IN ('image', 'audio', 'video')
  );

-- 3. send_chat_message will accept it.
--
-- Rewritten from its own live definition rather than restated, because the
-- function is a hundred lines of guards that have accumulated across six
-- migrations and retyping them is how one gets dropped.
DO $$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'send_chat_message'
     AND pg_get_function_identity_arguments(p.oid)
         = 'p_room_id uuid, p_payload text, p_attached_post_id uuid, p_media_path text, p_media_type text';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'send_chat_message not found — cannot teach it about video';
  END IF;

  IF position('''image'', ''audio''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'the media-type guard is not where it was; refusing to patch blind';
  END IF;

  v_def := replace(v_def, '''image'', ''audio''', '''image'', ''audio'', ''video''');

  -- pg_get_functiondef omits the trailing semicolon.
  EXECUTE v_def || ';';
END;
$$;

-- 4. The inbox will describe it.
--
-- Same treatment, for the same reason: inbox_rooms is ninety lines and has
-- been redefined seven times.
DO $$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_viewdef('public.inbox_rooms'::regclass, true) INTO v_def;

  IF position('WHEN ''image''::text THEN ''Photo''::text' IN v_def) = 0 THEN
    RAISE EXCEPTION 'the preview CASE is not where it was; refusing to patch blind';
  END IF;

  v_def := replace(
    v_def,
    'WHEN ''image''::text THEN ''Photo''::text',
    'WHEN ''image''::text THEN ''Photo''::text
                            WHEN ''video''::text THEN ''Video''::text'
  );

  EXECUTE 'CREATE OR REPLACE VIEW public.inbox_rooms WITH (security_invoker = true) AS '
          || v_def;
END;
$$;

GRANT SELECT ON public.inbox_rooms TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.inbox_rooms FROM authenticated, anon;

SELECT public.record_migration(
  '20261048090000', 'short_clips_in_a_chat'
);

NOTIFY pgrst, 'reload schema';
