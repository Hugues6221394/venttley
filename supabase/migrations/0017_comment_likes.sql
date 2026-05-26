-- 0017 — Comment likes
--
-- Adds a SECURITY DEFINER toggle RPC for comment_likes and extends
-- fetch_comment_tree() to return a liked_by_me flag for the current user.
-- comment_likes table itself already exists from 0001_init_schema.sql.

-- Idempotent guard: composite PK already defined in 0001, so no schema change there.

CREATE INDEX IF NOT EXISTS comment_likes_user_idx
    ON public.comment_likes (user_id);

-- ---------------------------------------------------------------------------
-- toggle_comment_like(p_comment_id UUID) -> BOOLEAN
--   Inserts a like row if missing (returns TRUE) or removes it (returns FALSE).
--   Keeps posts_comments.likes_count in sync atomically.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.toggle_comment_like(p_comment_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    uid     UUID := auth.uid();
    deleted INT;
BEGIN
    IF uid IS NULL THEN
        RAISE EXCEPTION 'auth required';
    END IF;

    DELETE FROM public.comment_likes
     WHERE comment_id = p_comment_id
       AND user_id    = uid;
    GET DIAGNOSTICS deleted = ROW_COUNT;

    IF deleted > 0 THEN
        UPDATE public.posts_comments
           SET likes_count = GREATEST(likes_count - 1, 0)
         WHERE comment_id = p_comment_id;
        RETURN FALSE;
    END IF;

    INSERT INTO public.comment_likes (comment_id, user_id)
    VALUES (p_comment_id, uid);

    UPDATE public.posts_comments
       SET likes_count = likes_count + 1
     WHERE comment_id = p_comment_id;

    RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.toggle_comment_like(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- fetch_comment_tree(p_post_id UUID) — extended to return liked_by_me
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.fetch_comment_tree(UUID);

CREATE OR REPLACE FUNCTION public.fetch_comment_tree(p_post_id UUID)
RETURNS TABLE (
    comment_id   UUID,
    parent_id    UUID,
    author_id    UUID,
    content      TEXT,
    path         ltree,
    depth        INT,
    likes_count  INT,
    liked_by_me  BOOLEAN,
    created_at   TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT c.comment_id,
           c.parent_id,
           c.author_id,
           c.content,
           c.path,
           (nlevel(c.path) - 1) AS depth,
           c.likes_count,
           EXISTS (
               SELECT 1
                 FROM public.comment_likes cl
                WHERE cl.comment_id = c.comment_id
                  AND cl.user_id    = auth.uid()
           ) AS liked_by_me,
           c.created_at
      FROM public.posts_comments c
     WHERE c.post_id    = p_post_id
       AND c.deleted_at IS NULL
     ORDER BY c.path ASC, c.created_at ASC;
$$;

GRANT EXECUTE ON FUNCTION public.fetch_comment_tree(UUID) TO authenticated, anon;
