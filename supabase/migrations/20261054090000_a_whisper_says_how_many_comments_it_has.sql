-- A whisper's comment count is the number of comments it has.
--
-- Reported from the phone: a whisper says 3 comments, you open the sheet, and
-- there is nothing there. It is the worst kind of wrong number — it invites
-- somebody to look for a conversation that does not exist, and on a whisper
-- about something hard, "3 comments" reads as three people who replied.
--
-- The counter was kept by hand:
--
--   IF TG_OP = 'INSERT' AND NEW.deleted_at IS NULL THEN
--       comments_count = comments_count + 1
--   ELSIF TG_OP = 'UPDATE' AND OLD.deleted_at IS NULL
--                          AND NEW.deleted_at IS NOT NULL THEN
--       comments_count = GREATEST(comments_count - 1, 0)
--
-- and the trigger was declared AFTER INSERT OR UPDATE OF deleted_at. So:
--
--   * a hard DELETE never fired it at all, and the count stayed high. Comments
--     are hard-deleted when an account is deleted and when a whisper is purged
--     — there is a DELETE trigger next to this one for clearing their mentions
--     — so this is not a theoretical path;
--   * restoring a comment (deleted_at back to NULL) did not put it back;
--   * anything that wrote the column directly, seed data included, was simply
--     believed forever after.
--
-- The count is now recomputed from the rows, which is what the posts counter
-- next door already does. A recompute cannot drift: it does not care how the
-- row got there or how many events it missed, and the answer after any
-- sequence of writes is the same as counting by hand.

CREATE OR REPLACE FUNCTION public._bump_whisper_comment_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  -- COALESCE, not pg_catalog.coalesce: it is a SQL construct rather than a
  -- function, so there is nothing for an empty search_path to fail to find.
  v_whisper UUID := COALESCE(NEW.whisper_id, OLD.whisper_id);
BEGIN
  UPDATE public.whispers w
     SET comments_count = (
         SELECT pg_catalog.count(*)
           FROM public.whisper_comments c
          WHERE c.whisper_id = v_whisper
            AND c.deleted_at IS NULL
     )
   WHERE w.whisper_id = v_whisper;
  RETURN NULL;
END;
$$;

-- The name stays, because thirty-odd migrations and a pgTAP suite refer to it,
-- but it no longer bumps anything.
COMMENT ON FUNCTION public._bump_whisper_comment_count() IS
  'Recomputes whispers.comments_count from whisper_comments. Named for what it '
  'used to do.';

DROP TRIGGER IF EXISTS whisper_comments_count_trg ON public.whisper_comments;
CREATE TRIGGER whisper_comments_count_trg
AFTER INSERT OR DELETE OR UPDATE OF deleted_at ON public.whisper_comments
FOR EACH ROW EXECUTE FUNCTION public._bump_whisper_comment_count();

-- And the counts that are already wrong.
--
-- Every whisper, not only the ones with comments: the reported case was a
-- whisper with a count of 3 and no rows at all, so the rows cannot be the
-- thing that drives the reconciliation.
UPDATE public.whispers w
   SET comments_count = c.live
  FROM (
    SELECT w2.whisper_id,
           (SELECT pg_catalog.count(*)
              FROM public.whisper_comments c2
             WHERE c2.whisper_id = w2.whisper_id
               AND c2.deleted_at IS NULL) AS live
      FROM public.whispers w2
  ) c
 WHERE w.whisper_id = c.whisper_id
   AND w.comments_count IS DISTINCT FROM c.live;

SELECT public.record_migration(
  '20261054090000', 'a_whisper_says_how_many_comments_it_has'
);

NOTIFY pgrst, 'reload schema';
