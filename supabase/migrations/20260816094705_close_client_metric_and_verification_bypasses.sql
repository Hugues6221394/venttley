BEGIN;

-- Provider-backed verification must be derived from Supabase Auth state. The
-- old function trusted any signed-in caller, so an email/password client could
-- mark its own profile verified without proving ownership.
CREATE OR REPLACE FUNCTION public.mark_email_verified()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_provider_verified BOOLEAN;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT
    (
      NULLIF(pg_catalog.btrim(auth_user.phone), '') IS NOT NULL
      AND auth_user.phone_confirmed_at IS NOT NULL
    )
    OR EXISTS (
      SELECT 1
        FROM auth.identities AS identity
       WHERE identity.user_id = auth_user.id
         AND identity.provider = 'google'
    )
    INTO v_provider_verified
    FROM auth.users AS auth_user
   WHERE auth_user.id = v_me;

  IF COALESCE(v_provider_verified, FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'provider_identity_not_verified' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.users
     SET email_verified = TRUE,
         updated_at = pg_catalog.now()
   WHERE user_id = v_me;

  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_email_verified()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_email_verified() TO authenticated;

-- queue_email is an internal primitive. Public flows call purpose-specific,
-- rate-limited RPCs such as request_email_verification(); allowing callers to
-- choose arbitrary templates and variables created a transactional-email spam
-- and content-injection surface.
REVOKE ALL ON FUNCTION public.queue_email(TEXT, UUID, JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_email(TEXT, UUID, JSONB) TO service_role;

-- record_whisper_listen is the canonical distinct-listener path. Retire the
-- pre-dedup counter primitive so repeated or anonymous calls cannot fabricate
-- plays_count.
REVOKE ALL ON FUNCTION public.bump_whisper_plays(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bump_whisper_plays(UUID) TO service_role;

-- Prompt answer counts are derived state. Keep them transactionally tied to
-- answer rows instead of trusting a second client RPC that can be duplicated,
-- omitted, or called for somebody else's prompt.
--
-- A pre-constraint production seed left one ownerless active prompt behind.
-- PostgreSQL correctly checks NOT VALID constraints on every rewritten row,
-- so quarantine any legacy prompt with ambiguous ownership before reconciling
-- counters. Nothing is deleted and historical answers remain readable.
ALTER TABLE public.plug_prompts
  DROP CONSTRAINT IF EXISTS plug_prompts_one_author;
UPDATE public.plug_prompts
   SET is_active = FALSE
 WHERE NOT (
   (plug_id IS NOT NULL AND author_id IS NULL)
   OR (plug_id IS NULL AND author_id IS NOT NULL)
 );
ALTER TABLE public.plug_prompts
  ADD CONSTRAINT plug_prompts_one_author
  CHECK (
    (plug_id IS NOT NULL AND author_id IS NULL)
    OR (plug_id IS NULL AND author_id IS NOT NULL)
  ) NOT VALID;

CREATE OR REPLACE FUNCTION private.maintain_prompt_answers_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.plug_prompts
       SET answers_count = answers_count + 1
     WHERE prompt_id = NEW.prompt_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.plug_prompts
       SET answers_count = GREATEST(answers_count - 1, 0)
     WHERE prompt_id = OLD.prompt_id;
    RETURN OLD;
  ELSIF NEW.prompt_id IS DISTINCT FROM OLD.prompt_id THEN
    UPDATE public.plug_prompts
       SET answers_count = GREATEST(answers_count - 1, 0)
     WHERE prompt_id = OLD.prompt_id;
    UPDATE public.plug_prompts
       SET answers_count = answers_count + 1
     WHERE prompt_id = NEW.prompt_id;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.maintain_prompt_answers_count()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS maintain_prompt_answers_count
  ON public.prompt_answers;
CREATE TRIGGER maintain_prompt_answers_count
  AFTER INSERT OR DELETE OR UPDATE OF prompt_id ON public.prompt_answers
  FOR EACH ROW EXECUTE FUNCTION private.maintain_prompt_answers_count();

UPDATE public.plug_prompts AS prompt
   SET answers_count = (
     SELECT pg_catalog.count(*)::INT
       FROM public.prompt_answers AS answer
      WHERE answer.prompt_id = prompt.prompt_id
   )
 WHERE (
   (prompt.plug_id IS NOT NULL AND prompt.author_id IS NULL)
   OR (prompt.plug_id IS NULL AND prompt.author_id IS NOT NULL)
 );

REVOKE ALL ON FUNCTION public.increment_prompt_answers(UUID)
  FROM PUBLIC, anon, authenticated;

-- Analytics is an outcome sink, not an arbitrary user-content store. Keep a
-- deliberately small set of scalar dimensions and discard every unknown,
-- nested, or oversized property before it reaches app_events.
CREATE OR REPLACE FUNCTION private.sanitize_event_props(p_props JSONB)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    pg_catalog.jsonb_object_agg(property.key, property.value),
    '{}'::JSONB
  )
    FROM pg_catalog.jsonb_each(
      CASE WHEN pg_catalog.jsonb_typeof(COALESCE(p_props, '{}'::JSONB)) = 'object'
           THEN COALESCE(p_props, '{}'::JSONB)
           ELSE '{}'::JSONB
      END
    ) AS property(key, value)
   WHERE property.key = ANY (ARRAY[
     'category', 'content_chars', 'destination', 'duration_seconds',
     'has_attached_post', 'has_audio', 'has_background', 'has_image',
     'has_music', 'has_note', 'has_persona', 'has_poll', 'has_title',
     'has_tribe', 'is_reply', 'is_story', 'mood', 'music_provider',
     'provider', 'query_chars', 'state', 'story_audience', 'target_type',
     'tribe_id', 'voice_filter'
   ])
     AND pg_catalog.jsonb_typeof(property.value) IN
       ('boolean', 'number', 'null', 'string')
     AND (
       pg_catalog.jsonb_typeof(property.value) <> 'string'
       OR pg_catalog.length(property.value #>> '{}') <= 120
     );
$$;

REVOKE ALL ON FUNCTION private.sanitize_event_props(JSONB)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.record_event(
  p_name TEXT,
  p_severity TEXT DEFAULT 'info',
  p_props JSONB DEFAULT '{}'::JSONB
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_id UUID;
  v_props JSONB;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_name IS NULL
     OR p_name !~ '^[A-Za-z0-9$][A-Za-z0-9._$-]{0,79}$' THEN
    RAISE EXCEPTION 'invalid_event_name' USING ERRCODE = 'P0001';
  END IF;
  IF p_severity NOT IN ('debug', 'info', 'warn', 'error') THEN
    RAISE EXCEPTION 'invalid_severity' USING ERRCODE = 'P0001';
  END IF;
  IF pg_catalog.octet_length(COALESCE(p_props, '{}'::JSONB)::TEXT) > 16384 THEN
    RAISE EXCEPTION 'event_props_too_large' USING ERRCODE = 'P0001';
  END IF;
  IF NOT public.claim_rate_limit('record_event', 60, 100) THEN
    RAISE EXCEPTION 'rate_limited' USING ERRCODE = 'P0001';
  END IF;

  v_props := private.sanitize_event_props(p_props);
  INSERT INTO public.app_events(user_id, name, severity, props)
  VALUES (v_uid, p_name, p_severity, v_props)
  RETURNING event_id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.record_event(TEXT, TEXT, JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_event(TEXT, TEXT, JSONB)
  TO authenticated;

-- Safety classifications may be raised by the author-side moderation hint,
-- but only trusted workers may clear or downgrade an existing classification.
CREATE OR REPLACE FUNCTION private.preserve_crisis_classification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    IF OLD.crisis_level = 'high' THEN
      NEW.crisis_level := 'high';
    ELSIF OLD.crisis_level = 'elevated' AND NEW.crisis_level IS NULL THEN
      NEW.crisis_level := 'elevated';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.preserve_crisis_classification()
  FROM PUBLIC, anon, authenticated;

DO $block$
DECLARE
  relation_name TEXT;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY[
    'posts', 'tribe_messages', 'chat_messages', 'whispers'
  ] LOOP
    EXECUTE pg_catalog.format(
      'DROP TRIGGER IF EXISTS preserve_crisis_classification ON public.%I',
      relation_name
    );
    EXECUTE pg_catalog.format(
      'CREATE TRIGGER preserve_crisis_classification '
      'BEFORE UPDATE OF crisis_level ON public.%I FOR EACH ROW '
      'EXECUTE FUNCTION private.preserve_crisis_classification()',
      relation_name
    );
  END LOOP;
END
$block$;

CREATE OR REPLACE FUNCTION public.set_post_crisis(
  p_post_id UUID,
  p_level TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_level IS NULL OR p_level NOT IN ('elevated', 'high') THEN
    RAISE EXCEPTION 'invalid_crisis_level' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.posts
     SET crisis_level = CASE
       WHEN crisis_level = 'high' OR p_level = 'high' THEN 'high'
       ELSE 'elevated'
     END
   WHERE post_id = p_post_id
     AND author_id = auth.uid();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'post_not_found_or_forbidden' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_tribe_message_crisis(
  p_message_id UUID,
  p_level TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_level IS NULL OR p_level NOT IN ('elevated', 'high') THEN
    RAISE EXCEPTION 'invalid_crisis_level' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.tribe_messages
     SET crisis_level = CASE
       WHEN crisis_level = 'high' OR p_level = 'high' THEN 'high'
       ELSE 'elevated'
     END
   WHERE message_id = p_message_id
     AND sender_id = auth.uid();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'message_not_found_or_forbidden' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_chat_message_crisis(
  p_message_id UUID,
  p_level TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_level IS NULL OR p_level NOT IN ('elevated', 'high') THEN
    RAISE EXCEPTION 'invalid_crisis_level' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.chat_messages
     SET crisis_level = CASE
       WHEN crisis_level = 'high' OR p_level = 'high' THEN 'high'
       ELSE 'elevated'
     END
   WHERE message_id = p_message_id
     AND sender_id = auth.uid();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'message_not_found_or_forbidden' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.set_post_crisis(UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.set_tribe_message_crisis(UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.set_chat_message_crisis(UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_post_crisis(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_tribe_message_crisis(UUID, TEXT)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_chat_message_crisis(UUID, TEXT)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
