-- A comment on a whisper can be a GIF.
--
-- Asked for directly: "ensure in comment section people can share GIFs,
-- emojis, you can like or reply". Likes and replies were already there. Emoji
-- need nothing from the database — they are characters in the text. GIFs need
-- somewhere to put the URL.
--
-- Post comments have had this since they were written (posts_comments.image_url
-- + image_path, a hotlinked Tenor URL and an optional uploaded copy), so this
-- is that column and that shape, one table over, rather than a second design
-- for the same thing. Only image_url: a whisper comment can carry a GIF, not an
-- upload, so there is no storage object to record a path for.
--
-- What is deliberately not copied: posts_comments allows empty content with no
-- image at all, because its check is only a length. This one keeps a content
-- rule and widens it — text, or a GIF, or both, and never neither.

ALTER TABLE public.whisper_comments
  ADD COLUMN IF NOT EXISTS image_url TEXT;

ALTER TABLE public.whisper_comments
  DROP CONSTRAINT IF EXISTS whisper_comments_content_check;

ALTER TABLE public.whisper_comments
  ADD CONSTRAINT whisper_comments_content_check
  CHECK (
    pg_catalog.length(public.whisper_comments.content) <= 500
    AND (
      pg_catalog.length(pg_catalog.btrim(public.whisper_comments.content)) > 0
      OR pg_catalog.length(COALESCE(public.whisper_comments.image_url, '')) > 0
    )
  );

-- Hotlinks only, and only over TLS. The picker returns a Tenor media URL and
-- nothing uploads anywhere, so anything that is not an https URL in this
-- column arrived from somewhere this app does not have a path for.
ALTER TABLE public.whisper_comments
  DROP CONSTRAINT IF EXISTS whisper_comments_image_url_check;

ALTER TABLE public.whisper_comments
  ADD CONSTRAINT whisper_comments_image_url_check
  CHECK (
    public.whisper_comments.image_url IS NULL
    OR (
      public.whisper_comments.image_url LIKE 'https://%'
      AND pg_catalog.length(public.whisper_comments.image_url) <= 2048
    )
  );

-- Writing one.
--
-- Dropped and recreated rather than replaced: a new defaulted parameter makes
-- a second overload, and then a four-argument call cannot tell them apart.
DROP FUNCTION IF EXISTS public.add_whisper_comment(UUID, TEXT, UUID, UUID);

CREATE FUNCTION public.add_whisper_comment(
  p_whisper_id UUID,
  p_content    TEXT,
  p_persona_id UUID DEFAULT NULL,
  p_parent_id  UUID DEFAULT NULL,
  p_image_url  TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me             UUID := (SELECT auth.uid());
  v_id             UUID;
  v_parent_whisper UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  -- A GIF on its own is a comment. Nothing at all is not.
  IF pg_catalog.btrim(COALESCE(p_content, '')) = ''
     AND COALESCE(p_image_url, '') = '' THEN
    RAISE EXCEPTION 'empty comment';
  END IF;

  IF p_image_url IS NOT NULL AND p_image_url NOT LIKE 'https://%' THEN
    RAISE EXCEPTION 'image must be an https url';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.whispers
     WHERE whisper_id = p_whisper_id AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'whisper not found';
  END IF;

  IF p_parent_id IS NOT NULL THEN
    SELECT whisper_id INTO v_parent_whisper
      FROM public.whisper_comments
     WHERE comment_id = p_parent_id AND deleted_at IS NULL;
    IF v_parent_whisper IS DISTINCT FROM p_whisper_id THEN
      RAISE EXCEPTION 'reply target not found';
    END IF;
  END IF;

  INSERT INTO public.whisper_comments
    (whisper_id, author_id, persona_id, content, parent_id, image_url)
  VALUES
    (p_whisper_id, v_me, p_persona_id,
     pg_catalog.btrim(COALESCE(p_content, '')),
     p_parent_id, p_image_url)
  RETURNING comment_id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION
  public.add_whisper_comment(UUID, TEXT, UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.add_whisper_comment(UUID, TEXT, UUID, UUID, TEXT)
  TO authenticated, service_role;

-- The retry-safe wrapper the client actually calls.
DROP FUNCTION IF EXISTS
  public.add_whisper_comment_idempotent(UUID, UUID, TEXT, UUID, UUID);

CREATE FUNCTION public.add_whisper_comment_idempotent(
  p_mutation_id UUID,
  p_whisper_id  UUID,
  p_content     TEXT,
  p_persona_id  UUID DEFAULT NULL,
  p_parent_id   UUID DEFAULT NULL,
  p_image_url   TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me          UUID := (SELECT auth.uid());
  v_resource_id UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  v_resource_id := private.existing_client_mutation(
    v_me, p_mutation_id, 'whisper_comment'
  );
  IF v_resource_id IS NOT NULL THEN RETURN v_resource_id; END IF;

  v_resource_id := public.add_whisper_comment(
    p_whisper_id, p_content, p_persona_id, p_parent_id, p_image_url
  );

  PERFORM private.complete_client_mutation(
    v_me, p_mutation_id, 'whisper_comment', v_resource_id
  );
  RETURN v_resource_id;
END;
$$;

REVOKE ALL ON FUNCTION
  public.add_whisper_comment_idempotent(UUID, UUID, TEXT, UUID, UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.add_whisper_comment_idempotent(UUID, UUID, TEXT, UUID, UUID, TEXT)
  TO authenticated, service_role;

-- Reading them. Dropped and recreated because a RETURNS TABLE gains a column,
-- which CREATE OR REPLACE will not do.
DROP FUNCTION IF EXISTS public.list_whisper_comments(UUID, INT, INT);

CREATE FUNCTION public.list_whisper_comments(
  p_whisper_id UUID,
  p_limit      INT DEFAULT 50,
  p_offset     INT DEFAULT 0
) RETURNS TABLE(
  comment_id         UUID,
  whisper_id         UUID,
  author_id          UUID,
  author_pseudonym   TEXT,
  author_avatar_seed VARCHAR,
  content            TEXT,
  created_at         TIMESTAMPTZ,
  parent_id          UUID,
  likes_count        INT,
  liked_by_me        BOOLEAN,
  can_delete         BOOLEAN,
  author_is_verified BOOLEAN,
  image_url          TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
BEGIN
  RETURN QUERY
  SELECT
    c.comment_id,
    c.whisper_id,
    c.author_id,
    COALESCE(pr.pseudonym, u.anonymous_pseudonym, 'anonymous')::TEXT,
    COALESCE(pr.avatar_seed, u.avatar_seed, 'default-orb')::VARCHAR,
    c.content::TEXT,
    c.created_at,
    c.parent_id,
    c.likes_count,
    EXISTS (
      SELECT 1 FROM public.whisper_comment_likes l
       WHERE l.comment_id = c.comment_id AND l.user_id = v_me
    ),
    (c.author_id = v_me OR w.author_id = v_me),
    CASE WHEN c.persona_id IS NULL
         THEN COALESCE(u.is_verified, FALSE) ELSE FALSE END,
    c.image_url
  FROM public.whisper_comments c
  JOIN public.whispers w        ON w.whisper_id  = c.whisper_id
  LEFT JOIN public.users u      ON u.user_id     = c.author_id
  LEFT JOIN public.personas pr  ON pr.persona_id = c.persona_id
                               AND pr.deleted_at IS NULL
  WHERE c.whisper_id = p_whisper_id
    AND c.deleted_at IS NULL
  ORDER BY c.created_at ASC
  OFFSET GREATEST(0, p_offset)
  LIMIT GREATEST(1, LEAST(p_limit, 200));
END;
$$;

REVOKE ALL ON FUNCTION public.list_whisper_comments(UUID, INT, INT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_whisper_comments(UUID, INT, INT)
  TO authenticated;

SELECT public.record_migration(
  '20261055090000', 'a_gif_belongs_in_a_whisper_comment'
);

NOTIFY pgrst, 'reload schema';
