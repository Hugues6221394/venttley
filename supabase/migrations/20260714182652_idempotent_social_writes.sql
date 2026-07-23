-- Exactly-once semantics for retryable social writes.
--
-- Mobile requests can commit in Postgres and still lose the HTTP response.
-- Retrying such a request must return the original resource instead of
-- creating another post, comment, or message. Existing RPCs remain available
-- for older app versions; new clients use the *_idempotent entrypoints.

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS private.client_mutation_receipts (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  mutation_id UUID NOT NULL,
  operation_kind TEXT NOT NULL CHECK (operation_kind IN (
    'post',
    'comment',
    'whisper_comment',
    'dm',
    'tribe_message'
  )),
  resource_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, mutation_id)
);

CREATE INDEX IF NOT EXISTS client_mutation_receipts_created_idx
  ON private.client_mutation_receipts (created_at);

ALTER TABLE private.client_mutation_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.client_mutation_receipts
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE private.client_mutation_receipts TO service_role;

-- Serialize only retries for the same user/key pair. Hash collisions merely
-- serialize two unrelated writes for one transaction; they cannot mix data.
CREATE OR REPLACE FUNCTION private.existing_client_mutation(
  p_user UUID,
  p_mutation_id UUID,
  p_operation_kind TEXT
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_existing_kind TEXT;
  v_resource_id UUID;
BEGIN
  IF p_user IS NULL OR p_mutation_id IS NULL THEN
    RAISE EXCEPTION 'authenticated user and mutation id are required';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      p_user::TEXT || ':' || p_mutation_id::TEXT,
      0
    )
  );

  SELECT r.operation_kind, r.resource_id
    INTO v_existing_kind, v_resource_id
    FROM private.client_mutation_receipts r
   WHERE r.user_id = p_user
     AND r.mutation_id = p_mutation_id;

  IF FOUND AND v_existing_kind IS DISTINCT FROM p_operation_kind THEN
    RAISE EXCEPTION 'mutation id already used for %', v_existing_kind;
  END IF;

  RETURN v_resource_id;
END;
$$;

CREATE OR REPLACE FUNCTION private.complete_client_mutation(
  p_user UUID,
  p_mutation_id UUID,
  p_operation_kind TEXT,
  p_resource_id UUID
) RETURNS VOID
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO private.client_mutation_receipts (
    user_id,
    mutation_id,
    operation_kind,
    resource_id
  ) VALUES (
    p_user,
    p_mutation_id,
    p_operation_kind,
    p_resource_id
  );
$$;

REVOKE ALL ON FUNCTION private.existing_client_mutation(UUID, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.complete_client_mutation(UUID, UUID, TEXT, UUID)
  FROM PUBLIC, anon, authenticated;

-- Posts previously used a direct Data API insert. This RPC preserves all
-- table constraints and write-guard triggers while ensuring author_id always
-- comes from the verified JWT.
CREATE OR REPLACE FUNCTION public.create_post_idempotent(
  p_mutation_id UUID,
  p_content TEXT,
  p_category_name TEXT,
  p_post_mood TEXT,
  p_tribe_id UUID DEFAULT NULL,
  p_space_id UUID DEFAULT NULL,
  p_persona_id UUID DEFAULT NULL,
  p_is_whisper BOOLEAN DEFAULT FALSE,
  p_image_path TEXT DEFAULT NULL,
  p_image_url TEXT DEFAULT NULL,
  p_audio_path TEXT DEFAULT NULL,
  p_audio_url TEXT DEFAULT NULL,
  p_audio_duration_seconds INT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_resource_id UUID;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  v_resource_id := private.existing_client_mutation(
    v_me,
    p_mutation_id,
    'post'
  );
  IF v_resource_id IS NOT NULL THEN
    RETURN v_resource_id;
  END IF;

  INSERT INTO public.posts (
    author_id,
    tribe_id,
    space_id,
    persona_id,
    category_name,
    post_type,
    content,
    post_mood,
    is_whisper,
    is_audio,
    image_path,
    image_url,
    audio_path,
    audio_url,
    audio_duration_seconds,
    media_status
  ) VALUES (
    v_me,
    p_tribe_id,
    p_space_id,
    p_persona_id,
    p_category_name,
    'user_post',
    p_content,
    p_post_mood::public.mood_badge_type,
    p_is_whisper,
    p_audio_url IS NOT NULL,
    p_image_path,
    p_image_url,
    p_audio_path,
    p_audio_url,
    p_audio_duration_seconds,
    CASE WHEN NULLIF(p_image_url, '') IS NULL THEN 'clean' ELSE 'pending' END
  ) RETURNING post_id INTO v_resource_id;

  PERFORM private.complete_client_mutation(
    v_me,
    p_mutation_id,
    'post',
    v_resource_id
  );
  RETURN v_resource_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_threaded_comment_idempotent(
  p_mutation_id UUID,
  p_post_id UUID,
  p_content TEXT,
  p_parent_id UUID DEFAULT NULL,
  p_persona_id UUID DEFAULT NULL,
  p_image_url TEXT DEFAULT NULL,
  p_image_path TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_resource_id UUID;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  v_resource_id := private.existing_client_mutation(
    v_me,
    p_mutation_id,
    'comment'
  );
  IF v_resource_id IS NOT NULL THEN
    RETURN v_resource_id;
  END IF;

  v_resource_id := public.create_threaded_comment(
    p_post_id,
    p_parent_id,
    v_me,
    p_content,
    p_persona_id,
    p_image_url,
    p_image_path
  );

  PERFORM private.complete_client_mutation(
    v_me,
    p_mutation_id,
    'comment',
    v_resource_id
  );
  RETURN v_resource_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.add_whisper_comment_idempotent(
  p_mutation_id UUID,
  p_whisper_id UUID,
  p_content TEXT,
  p_persona_id UUID DEFAULT NULL,
  p_parent_id UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_resource_id UUID;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  v_resource_id := private.existing_client_mutation(
    v_me,
    p_mutation_id,
    'whisper_comment'
  );
  IF v_resource_id IS NOT NULL THEN
    RETURN v_resource_id;
  END IF;

  v_resource_id := public.add_whisper_comment(
    p_whisper_id,
    p_content,
    p_persona_id,
    p_parent_id
  );

  PERFORM private.complete_client_mutation(
    v_me,
    p_mutation_id,
    'whisper_comment',
    v_resource_id
  );
  RETURN v_resource_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.send_tribe_message_idempotent(
  p_mutation_id UUID,
  p_tribe_id UUID,
  p_content TEXT DEFAULT NULL,
  p_persona_id UUID DEFAULT NULL,
  p_image_url TEXT DEFAULT NULL,
  p_image_path TEXT DEFAULT NULL,
  p_audio_url TEXT DEFAULT NULL,
  p_audio_path TEXT DEFAULT NULL,
  p_audio_duration_seconds INT DEFAULT NULL,
  p_reply_to_message_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_resource_id UUID;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  v_resource_id := private.existing_client_mutation(
    v_me,
    p_mutation_id,
    'tribe_message'
  );
  IF v_resource_id IS NOT NULL THEN
    RETURN v_resource_id;
  END IF;

  v_resource_id := public.send_tribe_message(
    p_tribe_id,
    p_content,
    p_persona_id,
    p_image_url,
    p_image_path,
    p_audio_url,
    p_audio_path,
    p_audio_duration_seconds,
    p_reply_to_message_id,
    p_metadata
  );

  PERFORM private.complete_client_mutation(
    v_me,
    p_mutation_id,
    'tribe_message',
    v_resource_id
  );
  RETURN v_resource_id;
END;
$$;

-- The previous reply RPC checked room membership but not room_status. Reuse
-- the original send RPC so replies inherit the active-room and media-path
-- checks instead of creating a second policy implementation.
CREATE OR REPLACE FUNCTION public.send_chat_message_v2(
  p_room_id UUID,
  p_plaintext TEXT,
  p_attached_post_id UUID DEFAULT NULL,
  p_media_path TEXT DEFAULT NULL,
  p_media_type TEXT DEFAULT NULL,
  p_parent_message_id UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_message_id UUID;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  IF p_parent_message_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
      FROM public.chat_messages m
     WHERE m.message_id = p_parent_message_id
       AND m.room_id = p_room_id
  ) THEN
    RAISE EXCEPTION 'parent message does not belong to this room';
  END IF;

  SELECT sent.message_id
    INTO v_message_id
    FROM public.send_chat_message(
      p_room_id,
      p_plaintext,
      p_attached_post_id,
      p_media_path,
      p_media_type
    ) AS sent
   LIMIT 1;

  IF v_message_id IS NULL THEN
    RAISE EXCEPTION 'send_chat_message returned no row';
  END IF;

  IF p_parent_message_id IS NOT NULL THEN
    UPDATE public.chat_messages
       SET parent_message_id = p_parent_message_id
     WHERE message_id = v_message_id
       AND sender_id = v_me;
  END IF;

  RETURN v_message_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.send_chat_message_idempotent(
  p_mutation_id UUID,
  p_room_id UUID,
  p_plaintext TEXT,
  p_attached_post_id UUID DEFAULT NULL,
  p_media_path TEXT DEFAULT NULL,
  p_media_type TEXT DEFAULT NULL,
  p_parent_message_id UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_resource_id UUID;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  v_resource_id := private.existing_client_mutation(
    v_me,
    p_mutation_id,
    'dm'
  );
  IF v_resource_id IS NOT NULL THEN
    RETURN v_resource_id;
  END IF;

  v_resource_id := public.send_chat_message_v2(
    p_room_id,
    p_plaintext,
    p_attached_post_id,
    p_media_path,
    p_media_type,
    p_parent_message_id
  );

  PERFORM private.complete_client_mutation(
    v_me,
    p_mutation_id,
    'dm',
    v_resource_id
  );
  RETURN v_resource_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_post_idempotent(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN,
  TEXT, TEXT, TEXT, TEXT, INT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_post_idempotent(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN,
  TEXT, TEXT, TEXT, TEXT, INT
) TO authenticated;

REVOKE ALL ON FUNCTION public.create_threaded_comment_idempotent(
  UUID, UUID, TEXT, UUID, UUID, TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_threaded_comment_idempotent(
  UUID, UUID, TEXT, UUID, UUID, TEXT, TEXT
) TO authenticated;

REVOKE ALL ON FUNCTION public.add_whisper_comment_idempotent(
  UUID, UUID, TEXT, UUID, UUID
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_whisper_comment_idempotent(
  UUID, UUID, TEXT, UUID, UUID
) TO authenticated;

REVOKE ALL ON FUNCTION public.send_tribe_message_idempotent(
  UUID, UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, INT, UUID, JSONB
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_tribe_message_idempotent(
  UUID, UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, INT, UUID, JSONB
) TO authenticated;

REVOKE ALL ON FUNCTION public.send_chat_message_v2(
  UUID, TEXT, UUID, TEXT, TEXT, UUID
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_chat_message_v2(
  UUID, TEXT, UUID, TEXT, TEXT, UUID
) TO authenticated;

REVOKE ALL ON FUNCTION public.send_chat_message_idempotent(
  UUID, UUID, TEXT, UUID, TEXT, TEXT, UUID
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_chat_message_idempotent(
  UUID, UUID, TEXT, UUID, TEXT, TEXT, UUID
) TO authenticated;

-- Receipts live for the account lifetime because failed sends are retained
-- until the user explicitly retries them. Pruning them by age would allow a
-- late retry to duplicate a write whose original response was lost. Account
-- deletion removes receipts through the auth.users foreign key cascade.

NOTIFY pgrst, 'reload schema';
