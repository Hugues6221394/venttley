-- Venttly | Accessible, author-selected vent card colors
--
-- Keep the palette server-owned so an untrusted client cannot publish
-- unreadable or transparent cards. The v2 RPC is additive: older installed
-- clients continue to use create_post_idempotent while newer clients persist
-- the selected style atomically with the post.

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS card_background_color TEXT,
  ADD COLUMN IF NOT EXISTS card_text_color TEXT;

ALTER TABLE public.posts
  DROP CONSTRAINT IF EXISTS posts_card_background_color_check,
  ADD CONSTRAINT posts_card_background_color_check CHECK (
    card_background_color IS NULL OR card_background_color IN (
      '#FFF7FA',
      '#FFE6EF',
      '#F1EAFF',
      '#E7F6F1',
      '#FFF1D6',
      '#231820'
    )
  ),
  DROP CONSTRAINT IF EXISTS posts_card_text_color_check,
  ADD CONSTRAINT posts_card_text_color_check CHECK (
    card_text_color IS NULL OR card_text_color IN (
      '#21161B',
      '#FFFFFF',
      '#B91452',
      '#5A3FA3',
      '#176C61'
    )
  );

CREATE OR REPLACE FUNCTION public.create_post_idempotent_v2(
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
  p_poll_options TEXT[] DEFAULT NULL,
  p_card_background_color TEXT DEFAULT NULL,
  p_card_text_color TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
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
  IF p_card_background_color IS NOT NULL
     AND p_card_background_color NOT IN (
       '#FFF7FA', '#FFE6EF', '#F1EAFF',
       '#E7F6F1', '#FFF1D6', '#231820'
     ) THEN
    RAISE EXCEPTION 'unsupported card background color';
  END IF;
  IF p_card_text_color IS NOT NULL
     AND p_card_text_color NOT IN (
       '#21161B', '#FFFFFF', '#B91452', '#5A3FA3', '#176C61'
     ) THEN
    RAISE EXCEPTION 'unsupported card text color';
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
    media_status,
    card_background_color,
    card_text_color
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
    CASE WHEN NULLIF(p_image_url, '') IS NULL THEN 'clean' ELSE 'pending' END,
    p_card_background_color,
    p_card_text_color
  ) RETURNING post_id INTO v_resource_id;

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

REVOKE ALL ON FUNCTION public.create_post_idempotent_v2(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN,
  TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT[], TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_post_idempotent_v2(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN,
  TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT[], TEXT, TEXT
) TO authenticated;

CREATE OR REPLACE VIEW public.feed_posts WITH (security_invoker = true) AS
 SELECT p.post_id,
    p.author_id,
    COALESCE('@'::text || pr.pseudonym::text, '@'::text || u.anonymous_pseudonym::text, '@anonymous'::text) AS author_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb'::character varying) AS author_avatar_seed,
        CASE
            WHEN p.persona_id IS NULL THEN u.profile_photo_url
            ELSE NULL::text
        END AS author_profile_photo_url,
    COALESCE(u.is_verified, false) AS author_is_verified,
    COALESCE(u.karma_points, 0) AS author_karma,
    p.persona_id,
    t.name AS tribe_name,
    t.slug AS tribe_slug,
    p.tribe_id,
    p.space_id,
    p.category_name,
    p.post_type,
    p.content,
    p.post_mood,
    p.is_whisper,
    p.location_bucket,
    p.likes_count,
    p.comments_count,
    p.view_count,
    p.image_url,
    p.audio_url,
    p.audio_duration_seconds,
    p.crisis_level,
    p.created_at,
    p.edited_at,
    p.deleted_at,
    p.locked_at,
    p.is_keeper_pick,
    p.keeper_pick_at,
    p.media_status,
    p.card_background_color,
    p.card_text_color
   FROM public.posts p
     LEFT JOIN public.users u ON u.user_id = p.author_id
     LEFT JOIN public.personas pr
       ON pr.persona_id = p.persona_id AND pr.deleted_at IS NULL
     LEFT JOIN public.tribes t ON t.tribe_id = p.tribe_id
  WHERE u.shadow_banned IS NOT TRUE
     OR p.author_id = (SELECT auth.uid());

GRANT SELECT ON public.feed_posts TO authenticated;
