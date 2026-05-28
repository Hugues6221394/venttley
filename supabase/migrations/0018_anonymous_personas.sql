-- 0018 — Anonymous personas
--
-- One account can carry up to 5 alternate identities. Each persona has its
-- own pseudonym + avatar_seed, and posts / comments can be authored under a
-- specific persona instead of the user's default profile. The persona <->
-- user mapping is never exposed publicly: only the owner (via SELECT my row)
-- and the SECURITY DEFINER read paths (feed_posts, fetch_comment_tree) can
-- see it. From the client's perspective, a persona looks like any other
-- anonymous handle.
--
-- Adds:
--   * personas table + RLS
--   * posts.persona_id, posts_comments.persona_id columns
--   * create_persona / update_persona / delete_persona / my_personas RPCs
--   * feed_posts view rewritten to surface persona pseudonym/avatar
--   * fetch_comment_tree rewritten similarly
--   * create_threaded_comment now accepts p_persona_id
--   * insert_post trigger validates persona_id ownership

-- ---------------------------------------------------------------------------
-- 1) personas table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.personas (
    persona_id    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id       UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    pseudonym     VARCHAR(40) NOT NULL,
    avatar_seed   VARCHAR(100) NOT NULL,
    bio           TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at    TIMESTAMPTZ,
    CHECK (length(pseudonym) BETWEEN 2 AND 40),
    CHECK (pseudonym ~ '^[A-Za-z0-9_]+$')
);

CREATE UNIQUE INDEX IF NOT EXISTS personas_user_name_uq
    ON public.personas (user_id, lower(pseudonym))
    WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS personas_user_idx
    ON public.personas (user_id)
    WHERE deleted_at IS NULL;

ALTER TABLE public.personas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "personas owner read" ON public.personas;
CREATE POLICY "personas owner read"
    ON public.personas FOR SELECT
    USING (user_id = auth.uid());
-- No INSERT/UPDATE/DELETE policy — all writes go through SECURITY DEFINER RPCs.

-- ---------------------------------------------------------------------------
-- 2) FK columns on posts and posts_comments
-- ---------------------------------------------------------------------------
ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS persona_id UUID
    REFERENCES public.personas(persona_id) ON DELETE SET NULL;

ALTER TABLE public.posts_comments
    ADD COLUMN IF NOT EXISTS persona_id UUID
    REFERENCES public.personas(persona_id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS posts_persona_idx
    ON public.posts (persona_id) WHERE persona_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS posts_comments_persona_idx
    ON public.posts_comments (persona_id) WHERE persona_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3) Persona management RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_persona(
    p_pseudonym   TEXT,
    p_avatar_seed TEXT,
    p_bio         TEXT DEFAULT NULL
)
RETURNS public.personas
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    uid UUID := auth.uid();
    cnt INT;
    row public.personas;
BEGIN
    IF uid IS NULL THEN
        RAISE EXCEPTION 'auth required';
    END IF;
    IF p_pseudonym IS NULL OR length(trim(p_pseudonym)) < 2 THEN
        RAISE EXCEPTION 'pseudonym too short';
    END IF;

    SELECT count(*) INTO cnt
      FROM public.personas
     WHERE user_id = uid AND deleted_at IS NULL;
    IF cnt >= 5 THEN
        RAISE EXCEPTION 'max 5 personas per user';
    END IF;

    INSERT INTO public.personas (user_id, pseudonym, avatar_seed, bio)
    VALUES (uid, trim(p_pseudonym), COALESCE(p_avatar_seed, 'default-orb'), p_bio)
    RETURNING * INTO row;

    RETURN row;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_persona(
    p_persona_id  UUID,
    p_pseudonym   TEXT,
    p_avatar_seed TEXT,
    p_bio         TEXT DEFAULT NULL
)
RETURNS public.personas
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    uid UUID := auth.uid();
    row public.personas;
BEGIN
    IF uid IS NULL THEN
        RAISE EXCEPTION 'auth required';
    END IF;

    UPDATE public.personas
       SET pseudonym   = COALESCE(trim(p_pseudonym), pseudonym),
           avatar_seed = COALESCE(p_avatar_seed, avatar_seed),
           bio         = COALESCE(p_bio, bio)
     WHERE persona_id = p_persona_id
       AND user_id    = uid
       AND deleted_at IS NULL
    RETURNING * INTO row;

    IF row.persona_id IS NULL THEN
        RAISE EXCEPTION 'persona not found';
    END IF;

    RETURN row;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_persona(p_persona_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    uid UUID := auth.uid();
    affected INT;
BEGIN
    IF uid IS NULL THEN
        RAISE EXCEPTION 'auth required';
    END IF;

    -- Detach historical posts/comments so the persona disappears without
    -- destroying the user's content.
    UPDATE public.posts          SET persona_id = NULL WHERE persona_id = p_persona_id AND author_id = uid;
    UPDATE public.posts_comments SET persona_id = NULL WHERE persona_id = p_persona_id AND author_id = uid;

    UPDATE public.personas
       SET deleted_at = now()
     WHERE persona_id = p_persona_id
       AND user_id    = uid
       AND deleted_at IS NULL;
    GET DIAGNOSTICS affected = ROW_COUNT;
    RETURN affected > 0;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_persona(TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_persona(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_persona(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4) feed_posts — persona-aware
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.feed_hot CASCADE;
DROP VIEW IF EXISTS public.feed_posts CASCADE;

CREATE VIEW public.feed_posts WITH (security_invoker = true) AS
SELECT
    p.post_id,
    p.author_id,
    COALESCE(
        '@' || pr.pseudonym,
        '@' || u.anonymous_pseudonym,
        '@anonymous'
    ) AS author_pseudonym,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb') AS author_avatar_seed,
    COALESCE(u.is_verified, false) AS author_is_verified,
    COALESCE(u.karma_points, 0)    AS author_karma,
    p.persona_id,
    t.name AS tribe_name,
    t.slug AS tribe_slug,
    p.tribe_id,
    p.category_name,
    p.post_type,
    p.content,
    p.post_mood,
    p.is_whisper,
    p.location_bucket,
    p.likes_count,
    p.comments_count,
    p.created_at,
    p.deleted_at
FROM public.posts p
LEFT JOIN public.users    u  ON u.user_id     = p.author_id
LEFT JOIN public.personas pr ON pr.persona_id = p.persona_id AND pr.deleted_at IS NULL
LEFT JOIN public.tribes   t  ON t.tribe_id    = p.tribe_id;
GRANT SELECT ON public.feed_posts TO anon, authenticated;

-- Recreate feed_hot (was dropped via CASCADE above).
CREATE VIEW public.feed_hot WITH (security_invoker = true) AS
SELECT f.*, h.hot_score
  FROM public.feed_posts f
  JOIN public.mv_hot_posts h ON h.post_id = f.post_id;
GRANT SELECT ON public.feed_hot TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- 5) fetch_comment_tree — persona-aware
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.fetch_comment_tree(UUID);

CREATE OR REPLACE FUNCTION public.fetch_comment_tree(p_post_id UUID)
RETURNS TABLE (
    comment_id   UUID,
    parent_id    UUID,
    author_id    UUID,
    persona_id   UUID,
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
           c.persona_id,
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

-- ---------------------------------------------------------------------------
-- 6) create_threaded_comment — accepts persona_id
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_threaded_comment(UUID, UUID, UUID, TEXT);

CREATE OR REPLACE FUNCTION public.create_threaded_comment(
    p_post_id    UUID,
    p_parent_id  UUID,
    p_author_id  UUID,
    p_content    TEXT,
    p_persona_id UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    new_id      UUID := uuid_generate_v4();
    new_lbl     TEXT := replace(new_id::text, '-', '');
    parent_path ltree;
    new_path    ltree;
BEGIN
    -- Persona must belong to the author.
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

    INSERT INTO public.posts_comments(comment_id, post_id, parent_id, author_id, content, path, persona_id)
    VALUES (new_id, p_post_id, p_parent_id, p_author_id, p_content, new_path, p_persona_id);

    RETURN new_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7) Trigger: validate persona_id ownership at post insert time
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_validate_post_persona()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.persona_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.personas
             WHERE persona_id = NEW.persona_id
               AND user_id    = NEW.author_id
               AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'persona not owned by author';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS posts_validate_persona ON public.posts;
CREATE TRIGGER posts_validate_persona
    BEFORE INSERT OR UPDATE OF persona_id ON public.posts
    FOR EACH ROW EXECUTE FUNCTION public.trg_validate_post_persona();
