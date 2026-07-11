-- 0048_comment_tree_edits.sql
--
-- Extend `fetch_comment_tree` to surface:
--   * edited_at   — drives "(edited)" footer in the comment widget
--   * deleted_at  — surfaces tombstones so reply threads don't orphan
--                   when a parent comment is soft-deleted
--
-- This replaces the version from migration 0017, which filtered
-- soft-deletes out entirely. Returning tombstones is the friendlier
-- pattern: replies stay anchored, the body just shows "Comment
-- removed by author".

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
    created_at   TIMESTAMPTZ,
    edited_at    TIMESTAMPTZ,
    deleted_at   TIMESTAMPTZ
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
               SELECT 1 FROM comment_likes l
                WHERE l.comment_id = c.comment_id
                  AND l.user_id    = auth.uid()
           ) AS liked_by_me,
           c.created_at,
           c.edited_at,
           c.deleted_at
    FROM   posts_comments c
    WHERE  c.post_id = p_post_id
    ORDER BY c.path ASC, c.created_at ASC;
$$;

NOTIFY pgrst, 'reload schema';
