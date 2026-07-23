-- 0111_fix_whisper_comments_list.sql
--
-- The whisper comments sheet has shown "Could not load comments" since launch:
-- list_whisper_comments declares author_pseudonym TEXT but the COALESCE over
-- personas.pseudonym / users.anonymous_pseudonym returns VARCHAR, so Postgres
-- aborts RETURN QUERY with 42804 ("structure of query does not match function
-- result type"). Comments were persisting fine — only the read path failed.
-- Fix: cast every returned column to the declared type explicitly.
--
-- Also adds whisper_comments to the supabase_realtime publication so open
-- comment sheets can live-update via postgres_changes (SELECT RLS from 0059
-- already scopes rows to deleted_at IS NULL).

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
        COALESCE(pr.pseudonym, u.anonymous_pseudonym, 'anonymous')::TEXT AS author_pseudonym,
        COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb')::VARCHAR  AS author_avatar_seed,
        c.content::TEXT,
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

-- Live comment delivery for open sheets.
DO $$
BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.whisper_comments;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
