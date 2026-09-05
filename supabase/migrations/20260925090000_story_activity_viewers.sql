-- Story activity has been failing for every story since July, and there was
-- never a list of who actually viewed one.
--
-- TWO PROBLEMS. THE FIRST IS THAT NOTHING WORKED AT ALL.
--
-- story_reactions_for_owner, from 20260727165257, guards ownership like this:
--
--     WHERE p.post_id = p_post_id
--       AND p.author_id = v_me
--       AND p.is_whisper = TRUE        -- <—
--       AND p.deleted_at IS NULL
--     ...
--     RAISE EXCEPTION 'story not found or not owned by caller';
--
-- That was correct when it was written: stories were flagged is_whisper.
-- Later the same day, 20260727190030 split the two concepts — it added
-- is_story, backfilled every audio-less is_whisper row to
-- is_story = TRUE, is_whisper = FALSE, and made them mutually exclusive
-- (`IF p_is_story AND p_is_whisper THEN RAISE`).
--
-- The guard was never updated. So after that migration NO story has
-- is_whisper = TRUE, the EXISTS check can never pass, and every call raises.
-- The viewer catches it and shows "Could not load story activity", which reads
-- like a network hiccup rather than a permanently broken screen. Opening Story
-- activity on your own story has not worked since.
--
-- Both flags are accepted below rather than just is_story, because the
-- backfill only moved rows with no audio: an audio story from before the split
-- may still legitimately carry is_whisper. Requiring either is right, and
-- narrowing it to one flag is what caused this in the first place.
--
-- THE SECOND IS THAT "12 UNIQUE VIEWS" IS NOT AN ANSWER.
--
-- story_views has recorded (post_id, viewer_id, viewed_at) with a primary key
-- across the first two since 0038, so the identities have been sitting there
-- the whole time — the sheet just printed posts.view_count and listed
-- reactions. Reacting is a much higher bar than watching, so the sheet showed
-- the small number and hid the useful one.
--
-- The author cannot read those rows directly: RLS on story_views allows
-- SELECT only where viewer_id = auth.uid(). That is the correct policy and is
-- left alone — this is SECURITY DEFINER and enforces the narrower rule that
-- matters, which is that only the story's author sees its viewers.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Repair the ownership guard
-- ---------------------------------------------------------------------------

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
       -- Either flag. See the note at the top: the split left old audio
       -- stories on is_whisper and new ones on is_story.
       AND (p.is_story = TRUE OR p.is_whisper = TRUE)
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
END $$;

REVOKE ALL ON FUNCTION public.story_reactions_for_owner(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.story_reactions_for_owner(UUID)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Who actually watched it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.story_viewers_for_owner(
  p_post_id UUID,
  p_limit   INT DEFAULT 200
) RETURNS TABLE (
  user_id UUID,
  pseudonym TEXT,
  avatar_seed TEXT,
  profile_photo_url TEXT,
  is_verified BOOLEAN,
  viewed_at TIMESTAMPTZ,
  reaction_type TEXT
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
       AND (p.is_story = TRUE OR p.is_whisper = TRUE)
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
    sv.viewed_at,
    -- Their reaction, if they left one. Joining it here means the sheet can
    -- show one list of people with a reaction badge against the ones who
    -- reacted, instead of two disconnected lists where the reactors are
    -- invisible among the viewers.
    pl.reaction_type::TEXT
  FROM public.story_views AS sv
  JOIN public.users AS u ON u.user_id = sv.viewer_id
  LEFT JOIN public.post_likes AS pl
         ON pl.post_id = sv.post_id AND pl.user_id = sv.viewer_id
  WHERE sv.post_id = p_post_id
    -- The author is not a viewer of their own story. mark_story_viewed skips
    -- self already; this makes the list correct even for rows written before
    -- it did.
    AND sv.viewer_id <> v_me
  ORDER BY sv.viewed_at DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
END $$;

COMMENT ON FUNCTION public.story_viewers_for_owner(UUID, INT) IS
  'Who viewed a story, newest first, with their reaction if any. Author only. story_views RLS lets a person read only their own row, so this SECURITY DEFINER function is the only way an author sees the list.';

REVOKE ALL ON FUNCTION public.story_viewers_for_owner(UUID, INT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.story_viewers_for_owner(UUID, INT)
  TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20260925090000', 'story_activity_viewers'
);

NOTIFY pgrst, 'reload schema';
