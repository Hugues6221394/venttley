-- A persona you can change your mind about.
--
-- People could make a persona and then nothing: no rename, no picture, no way
-- to delete it. The database has had update_persona and delete_persona all
-- along — the app simply never offered them — and a persona has only ever had
-- a generated avatar seed, so a post written under one showed no face at all.
--
-- The rule the owner stated, which is the right one: anything a person makes
-- in this app, they can edit and they can delete.

ALTER TABLE public.personas
  ADD COLUMN IF NOT EXISTS profile_photo_url TEXT,
  ADD COLUMN IF NOT EXISTS photo_path TEXT;

COMMENT ON COLUMN public.personas.profile_photo_url IS
  'A picture for this persona, from the gallery. Null means fall back to the '
  'generated avatar_seed, which every persona always has.';

------------------------------------------------------------------------------
-- 1. Make and change one.
------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_persona(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.create_persona(
  p_pseudonym   TEXT,
  p_avatar_seed TEXT,
  p_bio         TEXT DEFAULT NULL,
  p_photo_url   TEXT DEFAULT NULL,
  p_photo_path  TEXT DEFAULT NULL
)
RETURNS public.personas
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  uid UUID := (SELECT auth.uid());
  row public.personas;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  IF btrim(COALESCE(p_pseudonym, '')) = '' THEN
    RAISE EXCEPTION 'persona needs a name';
  END IF;

  INSERT INTO public.personas
    (user_id, pseudonym, avatar_seed, bio, profile_photo_url, photo_path)
  VALUES (uid, btrim(p_pseudonym), p_avatar_seed, p_bio, p_photo_url, p_photo_path)
  RETURNING * INTO row;

  RETURN row;
END $$;

DROP FUNCTION IF EXISTS public.update_persona(UUID, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.update_persona(
  p_persona_id  UUID,
  p_pseudonym   TEXT,
  p_avatar_seed TEXT,
  p_bio         TEXT DEFAULT NULL,
  p_clear_bio   BOOLEAN DEFAULT FALSE
)
RETURNS public.personas
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  uid UUID := (SELECT auth.uid());
  row public.personas;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  UPDATE public.personas
     SET pseudonym   = COALESCE(NULLIF(btrim(p_pseudonym), ''), pseudonym),
         avatar_seed = COALESCE(p_avatar_seed, avatar_seed),
         -- COALESCE alone cannot express "empty it": passing NULL means "leave
         -- it", which made a bio impossible to remove once written.
         bio         = CASE WHEN p_clear_bio THEN NULL
                            ELSE COALESCE(p_bio, bio) END
   WHERE persona_id = p_persona_id
     AND user_id    = uid
     AND deleted_at IS NULL
  RETURNING * INTO row;

  IF row.persona_id IS NULL THEN RAISE EXCEPTION 'persona not found'; END IF;
  RETURN row;
END $$;

------------------------------------------------------------------------------
-- 2. Give one a face, or take it away.
------------------------------------------------------------------------------
-- Both return the path that was there before, so the caller can delete the old
-- file from storage. Same shape as set_user_profile_photo, for the same
-- reason: the upload has already happened by the time this is called, and an
-- orphaned image in a bucket is somebody's face nobody is paying attention to.
CREATE OR REPLACE FUNCTION public.set_persona_photo(
  p_persona_id UUID,
  p_path       TEXT,
  p_url        TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  uid      UUID := (SELECT auth.uid());
  old_path TEXT;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  SELECT p.photo_path INTO old_path
    FROM public.personas p
   WHERE p.persona_id = p_persona_id AND p.user_id = uid AND p.deleted_at IS NULL;

  UPDATE public.personas
     SET profile_photo_url = p_url, photo_path = p_path
   WHERE persona_id = p_persona_id AND user_id = uid AND deleted_at IS NULL;

  IF NOT FOUND THEN RAISE EXCEPTION 'persona not found'; END IF;
  RETURN old_path;
END $$;

CREATE OR REPLACE FUNCTION public.clear_persona_photo(p_persona_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  uid      UUID := (SELECT auth.uid());
  old_path TEXT;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  SELECT p.photo_path INTO old_path
    FROM public.personas p
   WHERE p.persona_id = p_persona_id AND p.user_id = uid AND p.deleted_at IS NULL;

  UPDATE public.personas
     SET profile_photo_url = NULL, photo_path = NULL
   WHERE persona_id = p_persona_id AND user_id = uid AND deleted_at IS NULL;

  IF NOT FOUND THEN RAISE EXCEPTION 'persona not found'; END IF;
  RETURN old_path;
END $$;

REVOKE ALL ON FUNCTION public.create_persona(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_persona(UUID, TEXT, TEXT, TEXT, BOOLEAN) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_persona_photo(UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.clear_persona_photo(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_persona(TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_persona(UUID, TEXT, TEXT, TEXT, BOOLEAN) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_persona_photo(UUID, TEXT, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.clear_persona_photo(UUID) TO authenticated, service_role;

------------------------------------------------------------------------------
-- 3. And the face shows up on what they wrote.
------------------------------------------------------------------------------
-- The view returned NULL for a post written under a persona, because there was
-- nothing to return. Now there can be.
-- WITH (security_invoker = true), and it is not optional. CREATE OR REPLACE
-- VIEW resets reloptions, so leaving it off silently turns the view back into
-- a definer view and row level security stops applying to every feed, search
-- and comment path that reads it. Three tests caught exactly that here.
CREATE OR REPLACE VIEW public.feed_posts
WITH (security_invoker = true) AS
 SELECT p.post_id,
    p.author_id,
    COALESCE('@'::TEXT || pr.pseudonym::TEXT, '@'::TEXT || u.anonymous_pseudonym::TEXT, '@anonymous'::TEXT) AS author_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb'::CHARACTER VARYING) AS author_avatar_seed,
        CASE
            WHEN p.persona_id IS NULL THEN u.profile_photo_url
            ELSE pr.profile_photo_url
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
    p.card_text_color,
    p.is_story,
    p.story_audience,
    p.music_track_id,
    p.music_start_ms,
    p.music_duration_ms,
    p.music_volume,
    p.goal_reached_at
   FROM posts p
     LEFT JOIN users u ON u.user_id = p.author_id
     LEFT JOIN personas pr ON pr.persona_id = p.persona_id AND pr.deleted_at IS NULL
     LEFT JOIN tribes t ON t.tribe_id = p.tribe_id
  WHERE ( SELECT private.can_view_post_author(p.author_id) AS can_view_post_author);

SELECT public.record_migration(
  '20261061090000', 'a_persona_you_can_change'
);

NOTIFY pgrst, 'reload schema';
