-- 0101_fix_comment_counts.sql
-- posts.comments_count drifted from reality: the thread shows the true replies
-- (from fetch_comment_tree) while the vent card shows a stale number (seed data
-- set static counts, and the old inc/dec triggers never handled SOFT deletes —
-- deleted_at is an UPDATE, not a DELETE). Replace the fragile inc/dec pair with
-- ONE self-healing recompute trigger that counts live (non-deleted) comments,
-- and backfill every post so existing threads read correctly immediately.

CREATE OR REPLACE FUNCTION public.recompute_post_comment_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_post UUID := COALESCE(NEW.post_id, OLD.post_id);
BEGIN
    UPDATE public.posts p
       SET comments_count = (
           SELECT count(*)
             FROM public.posts_comments c
            WHERE c.post_id = v_post
              AND c.deleted_at IS NULL
       )
     WHERE p.post_id = v_post;
    RETURN NULL;
END;
$$;

-- Retire the drift-prone inc/dec triggers in favour of the recompute one.
DROP TRIGGER IF EXISTS comments_inc ON public.posts_comments;
DROP TRIGGER IF EXISTS comments_dec ON public.posts_comments;
DROP TRIGGER IF EXISTS posts_comments_recount ON public.posts_comments;
CREATE TRIGGER posts_comments_recount
    AFTER INSERT OR DELETE OR UPDATE OF deleted_at ON public.posts_comments
    FOR EACH ROW EXECUTE FUNCTION public.recompute_post_comment_count();

-- One-time backfill so every existing vent's count matches its live thread.
UPDATE public.posts p
   SET comments_count = (
       SELECT count(*)
         FROM public.posts_comments c
        WHERE c.post_id = p.post_id
          AND c.deleted_at IS NULL
   );

NOTIFY pgrst, 'reload schema';
