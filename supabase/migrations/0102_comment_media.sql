-- 0102_comment_media.sql
-- Replies can now carry a photo (device upload → post-media bucket) or a GIF
-- (remote Tenor/Giphy URL). Both land in posts_comments.image_url. An
-- image-only reply is allowed (content may be '').

ALTER TABLE public.posts_comments
    ADD COLUMN IF NOT EXISTS image_url  TEXT,
    ADD COLUMN IF NOT EXISTS image_path TEXT;

-- create_threaded_comment: accept an optional image. Keeps the existing
-- persona ownership check + ltree path logic. Drop the old 5-arg signature so
-- PostgREST doesn't see two overloads.
DROP FUNCTION IF EXISTS public.create_threaded_comment(UUID, UUID, UUID, TEXT, UUID);
CREATE OR REPLACE FUNCTION public.create_threaded_comment(
    p_post_id    UUID,
    p_parent_id  UUID,
    p_author_id  UUID,
    p_content    TEXT,
    p_persona_id UUID DEFAULT NULL,
    p_image_url  TEXT DEFAULT NULL,
    p_image_path TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    new_id      UUID := uuid_generate_v4();
    new_lbl     TEXT := replace(new_id::text, '-', '');
    parent_path ltree;
    new_path    ltree;
BEGIN
    IF p_persona_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.personas
             WHERE persona_id = p_persona_id
               AND user_id    = p_author_id
               AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'persona not owned by author';
        END IF;
    END IF;

    -- An empty comment is only allowed when it carries an image.
    IF btrim(coalesce(p_content, '')) = '' AND coalesce(p_image_url, '') = '' THEN
        RAISE EXCEPTION 'empty comment';
    END IF;

    IF p_parent_id IS NULL THEN
        new_path := text2ltree(new_lbl);
    ELSE
        SELECT path INTO parent_path
        FROM   public.posts_comments
        WHERE  comment_id = p_parent_id;
        IF parent_path IS NULL THEN
            RAISE EXCEPTION 'parent comment not found';
        END IF;
        new_path := parent_path || text2ltree(new_lbl);
    END IF;

    INSERT INTO public.posts_comments(
        comment_id, post_id, parent_id, author_id, content, path,
        persona_id, image_url, image_path)
    VALUES (
        new_id, p_post_id, p_parent_id, p_author_id, coalesce(p_content, ''),
        new_path, p_persona_id, p_image_url, p_image_path);

    RETURN new_id;
END;
$$;

-- fetch_comment_tree: surface the image alongside each comment. Return-table
-- shape changed, so the old function must be dropped first.
DROP FUNCTION IF EXISTS public.fetch_comment_tree(UUID);
CREATE OR REPLACE FUNCTION public.fetch_comment_tree(p_post_id UUID)
RETURNS TABLE (
    comment_id   UUID,
    parent_id    UUID,
    author_id    UUID,
    content      TEXT,
    image_url    TEXT,
    path         ltree,
    depth        INT,
    likes_count  INT,
    liked_by_me  BOOLEAN,
    created_at   TIMESTAMPTZ,
    edited_at    TIMESTAMPTZ,
    deleted_at   TIMESTAMPTZ,
    pinned_at    TIMESTAMPTZ
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
           c.image_url,
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
           c.deleted_at,
           c.pinned_at
    FROM   posts_comments c
    WHERE  c.post_id = p_post_id
    ORDER BY c.path ASC, c.created_at ASC;
$$;

NOTIFY pgrst, 'reload schema';
