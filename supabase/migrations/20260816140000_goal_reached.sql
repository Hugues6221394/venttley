-- Goals need one thing a vent does not have: an ending.
--
-- Today a "Goal" is only a post in the dreams_goals category, so a Goals page
-- built on what exists would be a filtered feed — the same cards, sorted the
-- same way, with no answer to the only question a goal raises: did they get
-- there? This adds that state and nothing else.
--
-- Deliberately NOT added: progress percentages, target dates, streaks, or a
-- completion score. Those are the same failure as the mood ring and "Tribe
-- health 55%" that were both deleted from this app — numbers nobody maintains,
-- presented with the authority of a measurement. `goal_reached_at` is set by
-- one person, about their own life, at the moment it becomes true. It is the
-- only fact here that anyone can actually vouch for.
--
-- Nullable, so every existing goal is correctly "still working on it" with no
-- backfill and no guessing.

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS goal_reached_at TIMESTAMPTZ;

-- Partial: the overwhelming majority of posts are not goals, and the page only
-- ever asks "this author's goals, reached first".
CREATE INDEX IF NOT EXISTS posts_goal_reached_idx
  ON public.posts (author_id, goal_reached_at DESC)
  WHERE category_name = 'dreams_goals' AND deleted_at IS NULL;

GRANT SELECT (goal_reached_at) ON public.posts TO anon, authenticated;

-- Author-only, and only on an actual goal. Marking someone else's goal reached
-- would be putting words in their mouth about their own life, so ownership is
-- checked server-side rather than left to the UI hiding a button.
CREATE OR REPLACE FUNCTION public.set_goal_reached(
  p_post_id UUID,
  p_reached BOOLEAN
) RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_author UUID;
  v_category TEXT;
  v_reached_at TIMESTAMPTZ;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT post.author_id, post.category_name
    INTO v_author, v_category
    FROM public.posts AS post
   WHERE post.post_id = p_post_id
     AND post.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'post not found'; END IF;
  IF v_author <> v_me THEN RAISE EXCEPTION 'not your goal'; END IF;
  IF v_category <> 'dreams_goals' THEN RAISE EXCEPTION 'not a goal'; END IF;

  -- Re-marking an already-reached goal keeps the original timestamp: the date
  -- someone got there is a fact about them, not a side effect of tapping twice.
  v_reached_at := CASE
    WHEN p_reached THEN COALESCE(
      (SELECT post.goal_reached_at FROM public.posts AS post
        WHERE post.post_id = p_post_id),
      now()
    )
    ELSE NULL
  END;

  UPDATE public.posts
     SET goal_reached_at = v_reached_at
   WHERE post_id = p_post_id;

  RETURN v_reached_at;
END;
$$;

REVOKE ALL ON FUNCTION public.set_goal_reached(UUID, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_goal_reached(UUID, BOOLEAN) TO authenticated;
