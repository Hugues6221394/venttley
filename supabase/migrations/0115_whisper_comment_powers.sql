-- 0115_whisper_comment_powers.sql
--
-- Instagram-style comment interactions on whispers:
--  * delete — comment author OR the whisper owner (moderation) can
--    soft-delete a comment
--  * likes  — whisper_comment_likes + denormalised likes_count
--  * replies — single-level threading via parent_id
--  * list_whisper_comments returns the new fields (liked_by_me,
--    can_delete, parent_id, likes_count)
--  * notifications: comment likes + replies-to-comment ride _notify()

-- ---------------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------------
ALTER TABLE public.whisper_comments
    ADD COLUMN IF NOT EXISTS parent_id UUID
        REFERENCES public.whisper_comments(comment_id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS likes_count INT NOT NULL DEFAULT 0
        CHECK (likes_count >= 0);

CREATE INDEX IF NOT EXISTS whisper_comments_parent_idx
    ON public.whisper_comments (parent_id)
    WHERE parent_id IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS public.whisper_comment_likes (
    comment_id UUID NOT NULL
        REFERENCES public.whisper_comments(comment_id) ON DELETE CASCADE,
    user_id    UUID NOT NULL
        REFERENCES public.users(user_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (comment_id, user_id)
);

ALTER TABLE public.whisper_comment_likes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "whisper comment likes read" ON public.whisper_comment_likes;
CREATE POLICY "whisper comment likes read"
    ON public.whisper_comment_likes FOR SELECT USING (true);

GRANT SELECT ON public.whisper_comment_likes TO authenticated;

CREATE OR REPLACE FUNCTION public._bump_whisper_comment_likes()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE whisper_comments SET likes_count = likes_count + 1
         WHERE comment_id = NEW.comment_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE whisper_comments SET likes_count = GREATEST(likes_count - 1, 0)
         WHERE comment_id = OLD.comment_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS whisper_comment_likes_count_trg ON public.whisper_comment_likes;
CREATE TRIGGER whisper_comment_likes_count_trg
    AFTER INSERT OR DELETE ON public.whisper_comment_likes
    FOR EACH ROW EXECUTE FUNCTION public._bump_whisper_comment_likes();

-- ---------------------------------------------------------------------------
-- 2. RPCs
-- ---------------------------------------------------------------------------

-- Author of the comment OR owner of the whisper may delete.
CREATE OR REPLACE FUNCTION public.delete_whisper_comment(p_comment_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me UUID := auth.uid();
    v_ok BOOLEAN;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

    UPDATE whisper_comments c
       SET deleted_at = now()
     WHERE c.comment_id = p_comment_id
       AND c.deleted_at IS NULL
       AND (
            c.author_id = v_me
            OR EXISTS (
                SELECT 1 FROM whispers w
                 WHERE w.whisper_id = c.whisper_id AND w.author_id = v_me
            )
       );
    GET DIAGNOSTICS v_ok = ROW_COUNT;
    RETURN v_ok;
END $$;

REVOKE ALL ON FUNCTION public.delete_whisper_comment(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_whisper_comment(UUID) TO authenticated;

-- Toggle like; returns the resulting liked state.
CREATE OR REPLACE FUNCTION public.toggle_whisper_comment_like(p_comment_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF EXISTS (
        SELECT 1 FROM whisper_comment_likes
         WHERE comment_id = p_comment_id AND user_id = v_me
    ) THEN
        DELETE FROM whisper_comment_likes
         WHERE comment_id = p_comment_id AND user_id = v_me;
        RETURN FALSE;
    ELSE
        INSERT INTO whisper_comment_likes (comment_id, user_id)
        VALUES (p_comment_id, v_me)
        ON CONFLICT DO NOTHING;
        RETURN TRUE;
    END IF;
END $$;

REVOKE ALL ON FUNCTION public.toggle_whisper_comment_like(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_whisper_comment_like(UUID) TO authenticated;

-- add_whisper_comment grows a reply target. Signature changes, so drop first.
DROP FUNCTION IF EXISTS public.add_whisper_comment(UUID, TEXT, UUID);
CREATE FUNCTION public.add_whisper_comment(
    p_whisper_id UUID,
    p_content    TEXT,
    p_persona_id UUID DEFAULT NULL,
    p_parent_id  UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_me UUID := auth.uid();
    v_id UUID;
    v_parent_whisper UUID;
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
    IF p_parent_id IS NOT NULL THEN
        SELECT whisper_id INTO v_parent_whisper
          FROM whisper_comments
         WHERE comment_id = p_parent_id AND deleted_at IS NULL;
        IF v_parent_whisper IS DISTINCT FROM p_whisper_id THEN
            RAISE EXCEPTION 'reply target not found';
        END IF;
    END IF;

    INSERT INTO whisper_comments (whisper_id, author_id, persona_id, content, parent_id)
    VALUES (p_whisper_id, v_me, p_persona_id, trim(p_content), p_parent_id)
    RETURNING comment_id INTO v_id;

    RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.add_whisper_comment(UUID, TEXT, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_whisper_comment(UUID, TEXT, UUID, UUID) TO authenticated;

-- list gains fields → return type changes → drop + recreate.
DROP FUNCTION IF EXISTS public.list_whisper_comments(UUID, INT, INT);
CREATE FUNCTION public.list_whisper_comments(
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
    created_at         TIMESTAMPTZ,
    parent_id          UUID,
    likes_count        INT,
    liked_by_me        BOOLEAN,
    can_delete         BOOLEAN
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public STABLE AS $$
DECLARE
    v_me UUID := auth.uid();
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
            SELECT 1 FROM whisper_comment_likes l
             WHERE l.comment_id = c.comment_id AND l.user_id = v_me
        ),
        (c.author_id = v_me OR w.author_id = v_me)
      FROM whisper_comments c
      JOIN whispers w       ON w.whisper_id  = c.whisper_id
      LEFT JOIN users    u  ON u.user_id     = c.author_id
      LEFT JOIN personas pr ON pr.persona_id = c.persona_id AND pr.deleted_at IS NULL
     WHERE c.whisper_id = p_whisper_id
       AND c.deleted_at IS NULL
     ORDER BY c.created_at ASC
     OFFSET GREATEST(0, p_offset)
     LIMIT GREATEST(1, LEAST(p_limit, 200));
END $$;

REVOKE ALL ON FUNCTION public.list_whisper_comments(UUID, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_whisper_comments(UUID, INT, INT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Notifications
-- ---------------------------------------------------------------------------

-- Likes on whisper comments → comment author, 5-minute grouping.
CREATE OR REPLACE FUNCTION public._trg_notify_whisper_comment_like()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_author  UUID;
    v_preview TEXT;
    v_whisper UUID;
BEGIN
    SELECT author_id, content, whisper_id INTO v_author, v_preview, v_whisper
      FROM whisper_comments WHERE comment_id = NEW.comment_id;
    PERFORM _notify(
        v_author, NEW.user_id, 'comment_like', 'whisper_comment', NEW.comment_id,
        'liked your comment', v_preview, INTERVAL '5 minutes',
        jsonb_build_object('whisper_id', v_whisper, 'comment_id', NEW.comment_id)
    );
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notify_whisper_comment_like_trg ON public.whisper_comment_likes;
CREATE TRIGGER notify_whisper_comment_like_trg
    AFTER INSERT ON public.whisper_comment_likes
    FOR EACH ROW EXECUTE FUNCTION public._trg_notify_whisper_comment_like();

-- Replies also ping the parent-comment author (whisper owner already
-- notified by the 0113 trigger).
CREATE OR REPLACE FUNCTION public._trg_notify_whisper_comment_reply()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_parent_author  UUID;
    v_whisper_author UUID;
BEGIN
    IF NEW.parent_id IS NULL THEN RETURN NEW; END IF;
    SELECT author_id INTO v_parent_author
      FROM whisper_comments WHERE comment_id = NEW.parent_id;
    SELECT author_id INTO v_whisper_author
      FROM whispers WHERE whisper_id = NEW.whisper_id;
    IF v_parent_author IS DISTINCT FROM v_whisper_author THEN
        PERFORM _notify(
            v_parent_author, NEW.author_id, 'comment_reply', 'whisper_comment',
            NEW.parent_id, 'replied to your comment', left(NEW.content, 60),
            INTERVAL '2 minutes',
            jsonb_build_object('whisper_id', NEW.whisper_id,
                               'comment_id', NEW.parent_id)
        );
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notify_whisper_comment_reply_trg ON public.whisper_comments;
CREATE TRIGGER notify_whisper_comment_reply_trg
    AFTER INSERT ON public.whisper_comments
    FOR EACH ROW EXECUTE FUNCTION public._trg_notify_whisper_comment_reply();
