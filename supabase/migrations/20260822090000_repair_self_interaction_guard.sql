-- Liking anything failed with: record "new" has no field "comment_id".
--
-- One trigger function, private.guard_no_self_interaction(), is attached to
-- five different tables — post_likes, comment_likes, whisper_reactions,
-- whisper_comment_likes and poll_votes. Those tables do not share a column set:
-- post_likes has post_id and no comment_id, comment_likes has the reverse.
--
-- A body that reads `NEW.comment_id` therefore only works on the tables that
-- happen to have that column, and the guard clause you would reach for does not
-- save you:
--
--     IF TG_TABLE_NAME = 'comment_likes' AND EXISTS (... NEW.comment_id ...)
--
-- **PostgreSQL does not guarantee short-circuit evaluation of AND.** The
-- planner is free to evaluate either side first, so the NEW.comment_id
-- reference can be resolved while the trigger is firing on post_likes, where
-- that field does not exist. The failure is a hard error at runtime, which is
-- why every like — on a post *and* on a comment — was rejected, and why it
-- could never have shown up at CREATE FUNCTION time.
--
-- The fix is to stop touching NEW's fields by name at all. `to_jsonb(NEW)`
-- converts the row once, and `->>` on a missing key returns NULL instead of
-- raising, so each branch can reference whichever key it likes regardless of
-- which table fired. That is what the repo has said since 20260815224342; this
-- migration exists because the database was left running an earlier body.
--
-- Idempotent: safe to run whether the live function is the old or new shape.

CREATE OR REPLACE FUNCTION private.guard_no_self_interaction()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  -- Converted once, by value. Nothing below names a column on NEW, so this
  -- function is indifferent to which of the five tables invoked it.
  v_new     JSONB := to_jsonb(NEW);
  v_actor   UUID  := (v_new->>'user_id')::UUID;
  v_post    UUID  := (v_new->>'post_id')::UUID;
  v_comment UUID  := (v_new->>'comment_id')::UUID;
  v_whisper UUID  := (v_new->>'whisper_id')::UUID;
  v_poll    UUID  := (v_new->>'poll_id')::UUID;
  v_option  UUID  := (v_new->>'option_id')::UUID;
BEGIN
  IF TG_TABLE_NAME = 'post_likes' THEN
    IF EXISTS (
      SELECT 1 FROM public.posts AS p
       WHERE p.post_id = v_post AND p.author_id = v_actor
    ) THEN
      RAISE EXCEPTION 'self_interaction_not_allowed';
    END IF;

  ELSIF TG_TABLE_NAME = 'comment_likes' THEN
    IF EXISTS (
      SELECT 1 FROM public.posts_comments AS c
       WHERE c.comment_id = v_comment AND c.author_id = v_actor
    ) THEN
      RAISE EXCEPTION 'self_interaction_not_allowed';
    END IF;

  ELSIF TG_TABLE_NAME = 'whisper_reactions' THEN
    IF EXISTS (
      SELECT 1 FROM public.whispers AS w
       WHERE w.whisper_id = v_whisper AND w.author_id = v_actor
    ) THEN
      RAISE EXCEPTION 'self_interaction_not_allowed';
    END IF;

  ELSIF TG_TABLE_NAME = 'whisper_comment_likes' THEN
    IF EXISTS (
      SELECT 1 FROM public.whisper_comments AS c
       WHERE c.comment_id = v_comment AND c.author_id = v_actor
    ) THEN
      RAISE EXCEPTION 'self_interaction_not_allowed';
    END IF;

  ELSIF TG_TABLE_NAME = 'poll_votes' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.poll_options AS o
       WHERE o.option_id = v_option AND o.poll_id = v_poll
    ) THEN
      RAISE EXCEPTION 'poll_option_mismatch';
    END IF;
    IF EXISTS (
      SELECT 1
        FROM public.post_polls AS poll
        JOIN public.posts AS post ON post.post_id = poll.post_id
       WHERE poll.poll_id = v_poll AND post.author_id = v_actor
    ) THEN
      RAISE EXCEPTION 'self_interaction_not_allowed';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.guard_no_self_interaction() FROM PUBLIC;

-- Nested IFs rather than `TG_TABLE_NAME = x AND EXISTS(...)` on one line: the
-- outer IF is a plain equality that cannot fault, and the subquery only runs
-- inside the branch that matched. Correctness here does not depend on the
-- planner's evaluation order.

NOTIFY pgrst, 'reload schema';
