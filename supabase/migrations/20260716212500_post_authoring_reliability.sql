-- Repair the canonical post-authoring contract after `is_audio` was removed
-- in migration 0007. All post types use this RPC, including Space posts,
-- stories, image posts, polls, audio posts, and outbox retries.

-- Historical keepers predate automatic keeper membership. Bring those rows
-- into the invariant expected by membership, Space, and moderation systems.
INSERT INTO public.tribe_members (tribe_id, user_id, role)
SELECT t.tribe_id, t.keeper_id, 'keeper'
  FROM public.tribes t
 WHERE t.keeper_id IS NOT NULL
ON CONFLICT (tribe_id, user_id)
DO UPDATE SET role = 'keeper';

-- The previous RPC has thirteen arguments. Replace it rather than leaving an
-- overloaded stale implementation in PostgREST's schema cache.
DROP FUNCTION IF EXISTS public.create_post_idempotent(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN,
  TEXT, TEXT, TEXT, TEXT, INT
);
DROP FUNCTION IF EXISTS public.create_post_idempotent(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN,
  TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT[]
);

CREATE FUNCTION public.create_post_idempotent(
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
  p_audio_duration_seconds INT DEFAULT NULL,
  p_poll_question TEXT DEFAULT NULL,
  p_poll_options TEXT[] DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
-- Legacy post event triggers call public badge helpers by unqualified name.
-- Keep the path explicit and constrained so those trigger functions resolve.
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_resource_id UUID;
  v_poll_id UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF p_mutation_id IS NULL THEN RAISE EXCEPTION 'mutation id required'; END IF;
  IF char_length(COALESCE(p_content, '')) > 1000 THEN
    RAISE EXCEPTION 'content too long';
  END IF;
  IF btrim(COALESCE(p_content, '')) = ''
     AND NULLIF(p_image_url, '') IS NULL
     AND NULLIF(p_audio_url, '') IS NULL THEN
    RAISE EXCEPTION 'post content or media required';
  END IF;
  IF p_space_id IS NOT NULL AND p_tribe_id IS NULL THEN
    RAISE EXCEPTION 'space requires tribe';
  END IF;
  IF p_space_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
      FROM public.spaces s
     WHERE s.space_id = p_space_id
       AND s.tribe_id = p_tribe_id
  ) THEN
    RAISE EXCEPTION 'space does not belong to tribe';
  END IF;
  IF (p_poll_question IS NULL) <> (p_poll_options IS NULL) THEN
    RAISE EXCEPTION 'poll question and options must be provided together';
  END IF;
  IF p_poll_question IS NOT NULL THEN
    IF char_length(btrim(p_poll_question)) NOT BETWEEN 4 AND 200 THEN
      RAISE EXCEPTION 'poll question must be 4 to 200 characters';
    END IF;
    IF cardinality(p_poll_options) NOT BETWEEN 2 AND 4 THEN
      RAISE EXCEPTION 'polls need 2 to 4 options';
    END IF;
    IF EXISTS (
      SELECT 1
        FROM unnest(p_poll_options) AS option_row(option_text)
       WHERE char_length(btrim(option_text)) NOT BETWEEN 1 AND 100
    ) THEN
      RAISE EXCEPTION 'poll options must be 1 to 100 characters';
    END IF;
    IF (
      SELECT count(DISTINCT lower(btrim(option_text)))
        FROM unnest(p_poll_options) AS option_row(option_text)
    ) <> cardinality(p_poll_options) THEN
      RAISE EXCEPTION 'poll options must be unique';
    END IF;
  END IF;

  v_resource_id := private.existing_client_mutation(
    v_me,
    p_mutation_id,
    'post'
  );
  IF v_resource_id IS NOT NULL THEN RETURN v_resource_id; END IF;

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
    COALESCE(p_content, ''),
    p_post_mood::public.mood_badge_type,
    p_is_whisper,
    NULLIF(p_image_path, ''),
    NULLIF(p_image_url, ''),
    NULLIF(p_audio_path, ''),
    NULLIF(p_audio_url, ''),
    p_audio_duration_seconds,
    CASE WHEN NULLIF(p_image_url, '') IS NULL THEN 'clean' ELSE 'pending' END
  ) RETURNING post_id INTO v_resource_id;

  -- Poll metadata and options commit with the parent post. Any validation,
  -- permission, or option-write failure rolls the whole post back.
  IF p_poll_question IS NOT NULL THEN
    INSERT INTO public.post_polls (post_id, question, closes_at)
    VALUES (v_resource_id, btrim(p_poll_question), now() + interval '3 days')
    RETURNING poll_id INTO v_poll_id;

    INSERT INTO public.poll_options (poll_id, option_text)
    SELECT v_poll_id, btrim(option_text)
      FROM unnest(p_poll_options) AS option_row(option_text);
  END IF;

  PERFORM private.complete_client_mutation(
    v_me,
    p_mutation_id,
    'post',
    v_resource_id
  );
  RETURN v_resource_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_post_idempotent(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN,
  TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT[]
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_post_idempotent(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN,
  TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT[]
) TO authenticated;

-- Creators retain full lifecycle control of their own posts. Editing is no
-- longer time-limited; media-only posts may clear their caption safely.
CREATE OR REPLACE FUNCTION public.edit_post(
  p_post_id UUID,
  p_content TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_post public.posts;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT * INTO v_post
    FROM public.posts
   WHERE post_id = p_post_id
     AND deleted_at IS NULL
   FOR UPDATE;
  IF v_post.post_id IS NULL THEN RAISE EXCEPTION 'post not found'; END IF;
  IF v_post.author_id <> v_me THEN RAISE EXCEPTION 'not your post'; END IF;
  IF char_length(COALESCE(p_content, '')) > 1000 THEN
    RAISE EXCEPTION 'content too long';
  END IF;
  IF btrim(COALESCE(p_content, '')) = ''
     AND NULLIF(v_post.image_url, '') IS NULL
     AND NULLIF(v_post.audio_url, '') IS NULL THEN
    RAISE EXCEPTION 'post content or media required';
  END IF;
  UPDATE public.posts
     SET content = COALESCE(p_content, ''), edited_at = now()
   WHERE post_id = p_post_id;
  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_post(p_post_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_author UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT author_id INTO v_author
    FROM public.posts
   WHERE post_id = p_post_id
   FOR UPDATE;
  IF v_author IS NULL THEN RAISE EXCEPTION 'post not found'; END IF;
  IF v_author <> v_me THEN RAISE EXCEPTION 'not your post'; END IF;
  UPDATE public.posts
     SET deleted_at = COALESCE(deleted_at, now())
   WHERE post_id = p_post_id;
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.edit_post(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_post(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edit_post(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_post(UUID) TO authenticated;

-- Poll permissions are enforced even if an older client exposes the toggle.
CREATE OR REPLACE FUNCTION public.guard_tribe_poll_write()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_tribe_id UUID; v_allow_polls BOOLEAN;
BEGIN
  SELECT p.tribe_id INTO v_tribe_id
    FROM public.posts p
   WHERE p.post_id = NEW.post_id;
  IF v_tribe_id IS NULL THEN RETURN NEW; END IF;
  SELECT COALESCE((t.settings->>'allow_polls')::BOOLEAN, TRUE)
    INTO v_allow_polls
    FROM public.tribes t
   WHERE t.tribe_id = v_tribe_id;
  IF NOT COALESCE(v_allow_polls, TRUE) THEN
    RAISE EXCEPTION 'polls_disabled_for_tribe';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_tribe_poll_write() FROM PUBLIC;
DROP TRIGGER IF EXISTS guard_tribe_poll_write ON public.post_polls;
CREATE TRIGGER guard_tribe_poll_write
  BEFORE INSERT ON public.post_polls
  FOR EACH ROW EXECUTE FUNCTION public.guard_tribe_poll_write();

NOTIFY pgrst, 'reload schema';
