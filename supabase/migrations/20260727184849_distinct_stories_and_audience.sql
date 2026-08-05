-- Stories and audio Whispers are different products. Historically both were
-- stored in posts.is_whisper, which leaked story-only behavior into the audio
-- feed and made the audience selector cosmetic. Keep the existing posts table
-- so reactions, reports, media cleanup, and moderation retain one lifecycle.

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS is_story BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS story_audience TEXT NOT NULL DEFAULT 'everyone';

ALTER TABLE public.posts
  DROP CONSTRAINT IF EXISTS posts_story_audience_check;

ALTER TABLE public.posts
  ADD CONSTRAINT posts_story_audience_check
  CHECK (story_audience IN ('everyone', 'friends'));

-- Preserve active legacy Stories. Genuine Whispers always have recorded audio.
-- The old rows were globally readable, so 'everyone' preserves their audience.
UPDATE public.posts
   SET is_story = TRUE,
       is_whisper = FALSE,
       story_audience = 'everyone'
 WHERE is_whisper = TRUE
   AND audio_url IS NULL
   AND audio_path IS NULL
   AND created_at > now() - INTERVAL '24 hours';

CREATE OR REPLACE FUNCTION public.create_post_idempotent_v3(
  p_mutation_id UUID,
  p_content TEXT,
  p_category_name TEXT,
  p_post_mood TEXT,
  p_tribe_id UUID DEFAULT NULL,
  p_space_id UUID DEFAULT NULL,
  p_persona_id UUID DEFAULT NULL,
  p_is_whisper BOOLEAN DEFAULT FALSE,
  p_is_story BOOLEAN DEFAULT FALSE,
  p_story_audience TEXT DEFAULT 'everyone',
  p_image_path TEXT DEFAULT NULL,
  p_image_url TEXT DEFAULT NULL,
  p_audio_path TEXT DEFAULT NULL,
  p_audio_url TEXT DEFAULT NULL,
  p_audio_duration_seconds INTEGER DEFAULT NULL,
  p_poll_question TEXT DEFAULT NULL,
  p_poll_options TEXT[] DEFAULT NULL,
  p_card_background_color TEXT DEFAULT NULL,
  p_card_text_color TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
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
  IF p_is_story AND p_is_whisper THEN
    RAISE EXCEPTION 'a post cannot be both a story and a whisper';
  END IF;
  IF p_story_audience NOT IN ('everyone', 'friends') THEN
    RAISE EXCEPTION 'unsupported story audience';
  END IF;
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
      FROM public.spaces AS s
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
    is_story,
    story_audience,
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
    p_is_story,
    CASE WHEN p_is_story THEN p_story_audience ELSE 'everyone' END,
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
    VALUES (v_resource_id, btrim(p_poll_question), now() + INTERVAL '3 days')
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

REVOKE ALL ON FUNCTION public.create_post_idempotent_v3(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN, BOOLEAN, TEXT,
  TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT[], TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_post_idempotent_v3(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN, BOOLEAN, TEXT,
  TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT[], TEXT, TEXT
) TO authenticated;

-- Keep already-installed clients compatible during a rolling release. In the
-- old contract, an is_whisper row without audio was a 24-hour Story.
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
  p_audio_duration_seconds INTEGER DEFAULT NULL,
  p_poll_question TEXT DEFAULT NULL,
  p_poll_options TEXT[] DEFAULT NULL,
  p_card_background_color TEXT DEFAULT NULL,
  p_card_text_color TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public.create_post_idempotent_v3(
    p_mutation_id => p_mutation_id,
    p_content => p_content,
    p_category_name => p_category_name,
    p_post_mood => p_post_mood,
    p_tribe_id => p_tribe_id,
    p_space_id => p_space_id,
    p_persona_id => p_persona_id,
    p_is_whisper => p_is_whisper
      AND (NULLIF(p_audio_url, '') IS NOT NULL OR NULLIF(p_audio_path, '') IS NOT NULL),
    p_is_story => p_is_whisper
      AND NULLIF(p_audio_url, '') IS NULL
      AND NULLIF(p_audio_path, '') IS NULL,
    p_story_audience => 'everyone',
    p_image_path => p_image_path,
    p_image_url => p_image_url,
    p_audio_path => p_audio_path,
    p_audio_url => p_audio_url,
    p_audio_duration_seconds => p_audio_duration_seconds,
    p_poll_question => p_poll_question,
    p_poll_options => p_poll_options,
    p_card_background_color => p_card_background_color,
    p_card_text_color => p_card_text_color
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_post_idempotent_v2(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN, TEXT, TEXT,
  TEXT, TEXT, INTEGER, TEXT, TEXT[], TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_post_idempotent_v2(
  UUID, TEXT, TEXT, TEXT, UUID, UUID, UUID, BOOLEAN, TEXT, TEXT,
  TEXT, TEXT, INTEGER, TEXT, TEXT[], TEXT, TEXT
) TO authenticated;

DROP POLICY IF EXISTS "posts readable" ON public.posts;
CREATE POLICY "posts readable"
ON public.posts
FOR SELECT
TO anon, authenticated
USING (
  deleted_at IS NULL
  AND (SELECT private.can_view_post_author(posts.author_id))
  AND (
    COALESCE(is_approved, TRUE)
    OR author_id = (SELECT auth.uid())
    OR public.can_manage_tribe(tribe_id)
    OR public.is_staff(
      (SELECT auth.uid()),
      ARRAY['super_admin', 'admin', 'moderator']
    )
  )
  AND (
    (hidden_at IS NULL AND archived_at IS NULL)
    OR author_id = (SELECT auth.uid())
    OR public.can_manage_tribe(tribe_id)
    OR public.is_staff(
      (SELECT auth.uid()),
      ARRAY['super_admin', 'admin', 'moderator']
    )
  )
  AND public.can_read_tribe_content(tribe_id, (SELECT auth.uid()))
  AND (
    is_story = FALSE
    OR story_audience = 'everyone'
    OR author_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1
        FROM public.friendships AS f
       WHERE f.status = 'accepted'
         AND (
           (f.user_a = (SELECT auth.uid()) AND f.user_b = posts.author_id)
           OR
           (f.user_b = (SELECT auth.uid()) AND f.user_a = posts.author_id)
         )
    )
  )
);

CREATE OR REPLACE VIEW public.feed_posts
WITH (security_invoker = true) AS
SELECT
  p.post_id,
  p.author_id,
  COALESCE(
    '@' || pr.pseudonym::TEXT,
    '@' || u.anonymous_pseudonym::TEXT,
    '@anonymous'
  ) AS author_pseudonym,
  COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb') AS author_avatar_seed,
  CASE WHEN p.persona_id IS NULL THEN u.profile_photo_url ELSE NULL END
    AS author_profile_photo_url,
  COALESCE(u.is_verified, FALSE) AS author_is_verified,
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
  p.card_text_color,
  p.is_story,
  p.story_audience
FROM public.posts AS p
LEFT JOIN public.users AS u ON u.user_id = p.author_id
LEFT JOIN public.personas AS pr
  ON pr.persona_id = p.persona_id
 AND pr.deleted_at IS NULL
LEFT JOIN public.tribes AS t ON t.tribe_id = p.tribe_id
WHERE (SELECT private.can_view_post_author(p.author_id));

CREATE OR REPLACE VIEW public.feed_hot
WITH (security_invoker = true) AS
SELECT
  f.post_id,
  f.author_id,
  f.author_pseudonym,
  f.author_avatar_seed,
  f.author_profile_photo_url,
  f.author_is_verified,
  f.author_karma,
  f.persona_id,
  f.tribe_name,
  f.tribe_slug,
  f.tribe_id,
  f.space_id,
  f.category_name,
  f.post_type,
  f.content,
  f.post_mood,
  f.is_whisper,
  f.location_bucket,
  f.likes_count,
  f.comments_count,
  f.view_count,
  f.image_url,
  f.audio_url,
  f.audio_duration_seconds,
  f.crisis_level,
  f.created_at,
  f.edited_at,
  f.deleted_at,
  f.locked_at,
  f.is_keeper_pick,
  f.keeper_pick_at,
  h.hot_score,
  f.is_story,
  f.story_audience
FROM public.feed_posts AS f
JOIN public.mv_hot_posts AS h ON h.post_id = f.post_id;

CREATE OR REPLACE FUNCTION public.friend_stories_for_me(
  p_limit INTEGER DEFAULT 24
)
RETURNS SETOF public.feed_posts
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT fp.*
    FROM public.feed_posts AS fp
   WHERE (SELECT auth.uid()) IS NOT NULL
     AND fp.is_story = TRUE
     AND fp.deleted_at IS NULL
     AND fp.created_at > now() - INTERVAL '24 hours'
     AND fp.author_id IS NOT NULL
     AND (
       fp.author_id = (SELECT auth.uid())
       OR EXISTS (
         SELECT 1
           FROM public.friendships AS f
          WHERE f.status = 'accepted'
            AND (
              (f.user_a = (SELECT auth.uid()) AND f.user_b = fp.author_id)
              OR
              (f.user_b = (SELECT auth.uid()) AND f.user_a = fp.author_id)
            )
       )
     )
   ORDER BY fp.created_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 24), 1), 100);
$$;

CREATE OR REPLACE FUNCTION public.personal_feed(
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0,
  p_category TEXT DEFAULT NULL,
  p_mood TEXT DEFAULT NULL
)
RETURNS TABLE(
  post_id UUID,
  author_id UUID,
  author_pseudonym TEXT,
  author_avatar_seed VARCHAR,
  author_profile_photo_url TEXT,
  author_is_verified BOOLEAN,
  author_karma INTEGER,
  tribe_name VARCHAR,
  tribe_slug TEXT,
  tribe_id UUID,
  category_name VARCHAR,
  post_type VARCHAR,
  content TEXT,
  post_mood public.mood_badge_type,
  is_whisper BOOLEAN,
  location_bucket TEXT,
  likes_count INTEGER,
  comments_count INTEGER,
  view_count INTEGER,
  image_url TEXT,
  audio_url TEXT,
  audio_duration_seconds INTEGER,
  crisis_level TEXT,
  created_at TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ,
  personal_score DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  v_uid UUID := auth.uid();
  v_bucket TEXT;
  v_cutoff_w TIMESTAMPTZ := now() - INTERVAL '24 hours';
  v_cutoff_a TIMESTAMPTZ := now() - INTERVAL '1 hour';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT lower(home_city)
    INTO v_bucket
    FROM public.users
   WHERE user_id = v_uid;

  RETURN QUERY
  WITH
  my_tribes AS (
    SELECT tm.tribe_id
      FROM public.tribe_members AS tm
     WHERE tm.user_id = v_uid
  ),
  my_categories AS (
    SELECT DISTINCT p.category_name
      FROM public.post_likes AS l
      JOIN public.posts AS p ON p.post_id = l.post_id
     WHERE l.user_id = v_uid
       AND l.created_at > now() - INTERVAL '30 days'
  ),
  my_blocks AS (
    SELECT ub.blocked_id
      FROM public.user_blocks AS ub
     WHERE ub.blocker_id = v_uid
  ),
  candidates AS (
    SELECT f.*, u.created_at AS author_created_at
      FROM public.feed_posts AS f
      JOIN public.users AS u ON u.user_id = f.author_id
     WHERE f.deleted_at IS NULL
       AND f.is_story = FALSE
       AND (f.is_whisper = FALSE OR f.created_at > v_cutoff_w)
       AND u.created_at < v_cutoff_a
       AND NOT EXISTS (
         SELECT 1 FROM my_blocks AS b WHERE b.blocked_id = f.author_id
       )
       AND (p_category IS NULL OR f.category_name = p_category)
       AND (p_mood IS NULL OR f.post_mood = p_mood::public.mood_badge_type)
  ),
  ranked AS (
    SELECT
      c.post_id,
      c.author_id,
      c.author_pseudonym,
      c.author_avatar_seed,
      c.author_profile_photo_url,
      c.author_is_verified,
      c.author_karma,
      c.tribe_name,
      c.tribe_slug,
      c.tribe_id,
      c.category_name,
      c.post_type,
      c.content,
      c.post_mood,
      c.is_whisper,
      c.location_bucket,
      c.likes_count,
      c.comments_count,
      c.view_count,
      c.image_url,
      c.audio_url,
      c.audio_duration_seconds,
      c.crisis_level,
      c.created_at,
      c.deleted_at,
      (
        log(GREATEST(c.likes_count + c.comments_count, 1))
        + public._venttly_age_decay(c.created_at)
        + CASE WHEN c.tribe_id IN (SELECT tribe_id FROM my_tribes)
               THEN 1.5 ELSE 0 END
        + CASE WHEN c.category_name IN (SELECT category_name FROM my_categories)
               THEN 0.8 ELSE 0 END
        + CASE WHEN v_bucket IS NOT NULL AND c.location_bucket = v_bucket
               THEN 0.6 ELSE 0 END
        - CASE WHEN c.comments_count > c.likes_count * 4
               THEN 0.8 ELSE 0 END
      )::DOUBLE PRECISION AS personal_score
    FROM candidates AS c
  )
  SELECT *
    FROM ranked
   ORDER BY personal_score DESC, created_at DESC
   OFFSET GREATEST(0, p_offset)
   LIMIT GREATEST(1, LEAST(p_limit, 100));
END;
$$;

GRANT SELECT ON public.feed_posts TO anon, authenticated;
GRANT SELECT ON public.feed_hot TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.friend_stories_for_me(INTEGER)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.personal_feed(INTEGER, INTEGER, TEXT, TEXT)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
