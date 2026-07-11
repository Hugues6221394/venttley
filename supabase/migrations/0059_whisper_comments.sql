-- 0059_whisper_comments.sql
--
-- Whisper comments — flat replies on audio whispers with denormalised counter.

CREATE TABLE IF NOT EXISTS public.whisper_comments (
    comment_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    whisper_id   UUID NOT NULL REFERENCES public.whispers(whisper_id) ON DELETE CASCADE,
    author_id    UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    persona_id   UUID REFERENCES public.personas(persona_id) ON DELETE SET NULL,
    content      TEXT NOT NULL CHECK (
        length(trim(content)) > 0 AND length(content) <= 500
    ),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS whisper_comments_whisper_idx
    ON public.whisper_comments (whisper_id, created_at ASC)
    WHERE deleted_at IS NULL;

ALTER TABLE public.whisper_comments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "whisper comments read" ON public.whisper_comments;
CREATE POLICY "whisper comments read"
    ON public.whisper_comments FOR SELECT
    USING (deleted_at IS NULL);

DROP POLICY IF EXISTS "whisper comments author insert" ON public.whisper_comments;
CREATE POLICY "whisper comments author insert"
    ON public.whisper_comments FOR INSERT
    WITH CHECK (author_id = auth.uid());

GRANT SELECT, INSERT ON public.whisper_comments TO authenticated;

-- Keep whispers.comments_count in sync.
CREATE OR REPLACE FUNCTION public._bump_whisper_comment_count()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.deleted_at IS NULL THEN
        UPDATE whispers
           SET comments_count = comments_count + 1
         WHERE whisper_id = NEW.whisper_id;
    ELSIF TG_OP = 'UPDATE' AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        UPDATE whispers
           SET comments_count = GREATEST(comments_count - 1, 0)
         WHERE whisper_id = NEW.whisper_id;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS whisper_comments_count_trg ON public.whisper_comments;
CREATE TRIGGER whisper_comments_count_trg
    AFTER INSERT OR UPDATE OF deleted_at ON public.whisper_comments
    FOR EACH ROW EXECUTE FUNCTION public._bump_whisper_comment_count();

-- ---------------------------------------------------------------------------
-- add_whisper_comment
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_whisper_comment(
    p_whisper_id UUID,
    p_content    TEXT,
    p_persona_id UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
    v_id UUID;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_content IS NULL OR length(trim(p_content)) = 0 THEN
        RAISE EXCEPTION 'empty comment';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM whispers
         WHERE whisper_id = p_whisper_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'whisper not found';
    END IF;

    INSERT INTO whisper_comments (whisper_id, author_id, persona_id, content)
    VALUES (p_whisper_id, v_me, p_persona_id, trim(p_content))
    RETURNING comment_id INTO v_id;

    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.add_whisper_comment(UUID, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_whisper_comment(UUID, TEXT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- list_whisper_comments — newest first for the sheet UI
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_whisper_comments(
    p_whisper_id UUID,
    p_limit      INT DEFAULT 50,
    p_offset     INT DEFAULT 0
) RETURNS TABLE (
    comment_id         UUID,
    whisper_id         UUID,
    author_id          UUID,
    author_pseudonym   TEXT,
    author_avatar_seed VARCHAR,
    content            TEXT,
    created_at         TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.comment_id,
        c.whisper_id,
        c.author_id,
        COALESCE(pr.pseudonym, u.anonymous_pseudonym, 'anonymous') AS author_pseudonym,
        COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb')       AS author_avatar_seed,
        c.content,
        c.created_at
      FROM whisper_comments c
      LEFT JOIN users    u  ON u.user_id     = c.author_id
      LEFT JOIN personas pr ON pr.persona_id = c.persona_id AND pr.deleted_at IS NULL
     WHERE c.whisper_id = p_whisper_id
       AND c.deleted_at IS NULL
     ORDER BY c.created_at DESC
     OFFSET GREATEST(0, p_offset)
     LIMIT GREATEST(1, LEAST(p_limit, 100));
END $$;

REVOKE ALL ON FUNCTION public.list_whisper_comments(UUID, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_whisper_comments(UUID, INT, INT) TO authenticated;
