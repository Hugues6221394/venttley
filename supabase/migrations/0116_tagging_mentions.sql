-- 0116_tagging_mentions.sql
--
-- Instagram-style tagging.
--  * resolve_tag(handle) — maps an @handle to a user (pseudonym) or a
--    tribe (slug, then unique name), users win ties.
--  * search_tag_candidates(prefix) — autocomplete for @ typing: friends
--    first, then other users, then tribes.
--  * Mention notifications — parses @handles out of new posts, post
--    comments and whisper comments; each mentioned user gets a 'mention'
--    notification (never grouped).

-- ---------------------------------------------------------------------------
-- 1. Tag resolution
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_tag(p_handle TEXT)
RETURNS TABLE (kind TEXT, id UUID, slug TEXT, display TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public STABLE AS $$
DECLARE
    v_handle TEXT := lower(trim(both '@' from COALESCE(p_handle, '')));
BEGIN
    IF v_handle = '' THEN RETURN; END IF;

    RETURN QUERY
    SELECT 'user'::TEXT, u.user_id, NULL::TEXT, u.anonymous_pseudonym::TEXT
      FROM users u
     WHERE lower(u.anonymous_pseudonym) = v_handle
       AND u.deactivated_at IS NULL
     LIMIT 1;
    IF FOUND THEN RETURN; END IF;

    RETURN QUERY
    SELECT 'tribe'::TEXT, t.tribe_id, t.slug::TEXT, t.name::TEXT
      FROM tribes t
     WHERE lower(t.slug) = v_handle OR lower(replace(t.name, ' ', '')) = v_handle
     LIMIT 1;
END $$;

REVOKE ALL ON FUNCTION public.resolve_tag(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_tag(TEXT) TO authenticated;

-- Autocomplete: friends first, then public users, then tribes.
CREATE OR REPLACE FUNCTION public.search_tag_candidates(
    p_prefix TEXT,
    p_limit  INT DEFAULT 8
) RETURNS TABLE (
    kind        TEXT,
    id          UUID,
    handle      TEXT,
    display     TEXT,
    avatar_seed TEXT,
    is_friend   BOOLEAN
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public STABLE AS $$
DECLARE
    v_me     UUID := auth.uid();
    v_prefix TEXT := lower(trim(both '@' from COALESCE(p_prefix, '')));
BEGIN
    IF length(v_prefix) < 1 THEN RETURN; END IF;

    RETURN QUERY
    (
        SELECT 'user'::TEXT, u.user_id,
               u.anonymous_pseudonym::TEXT,
               u.anonymous_pseudonym::TEXT,
               u.avatar_seed::TEXT,
               EXISTS (
                   SELECT 1 FROM friendships f
                    WHERE f.status = 'accepted'
                      AND ((f.user_a = v_me AND f.user_b = u.user_id)
                        OR (f.user_b = v_me AND f.user_a = u.user_id))
               ) AS is_friend
          FROM users u
         WHERE lower(u.anonymous_pseudonym) LIKE v_prefix || '%'
           AND u.deactivated_at IS NULL
           AND u.user_id <> v_me
         ORDER BY is_friend DESC, length(u.anonymous_pseudonym)
         LIMIT GREATEST(1, LEAST(p_limit, 15))
    )
    UNION ALL
    (
        SELECT 'tribe'::TEXT, t.tribe_id,
               t.slug::TEXT,
               t.name::TEXT,
               NULL::TEXT,
               FALSE
          FROM tribes t
         WHERE lower(t.slug) LIKE v_prefix || '%'
            OR lower(t.name) LIKE v_prefix || '%'
         ORDER BY length(t.slug)
         LIMIT 4
    );
END $$;

REVOKE ALL ON FUNCTION public.search_tag_candidates(TEXT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_tag_candidates(TEXT, INT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Mention notifications
-- ---------------------------------------------------------------------------
-- Extracts distinct @handles and notifies each matching user. Mentions
-- never group; self-mentions and the content author are skipped by _notify.
CREATE OR REPLACE FUNCTION public._notify_mentions(
    p_actor   UUID,
    p_content TEXT,
    p_subject_type TEXT,
    p_subject_id   UUID,
    p_extra   JSONB
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_handle TEXT;
    v_target UUID;
BEGIN
    IF p_content IS NULL THEN RETURN; END IF;
    FOR v_handle IN
        SELECT DISTINCT lower(m[1])
          FROM regexp_matches(p_content, '@([A-Za-z0-9_.-]{2,32})', 'g') AS m
        LIMIT 10
    LOOP
        SELECT user_id INTO v_target
          FROM users
         WHERE lower(anonymous_pseudonym) = v_handle AND deactivated_at IS NULL;
        IF v_target IS NOT NULL THEN
            PERFORM _notify(
                v_target, p_actor, 'mention', p_subject_type, p_subject_id,
                'mentioned you', left(p_content, 60), NULL, p_extra
            );
        END IF;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public._trg_mentions_post()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    PERFORM _notify_mentions(
        NEW.author_id, NEW.content, 'post', NEW.post_id,
        jsonb_build_object('post_id', NEW.post_id)
    );
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS mentions_post_trg ON public.posts;
CREATE TRIGGER mentions_post_trg
    AFTER INSERT ON public.posts
    FOR EACH ROW EXECUTE FUNCTION public._trg_mentions_post();

CREATE OR REPLACE FUNCTION public._trg_mentions_post_comment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    PERFORM _notify_mentions(
        NEW.author_id, NEW.content, 'comment', NEW.comment_id,
        jsonb_build_object('post_id', NEW.post_id, 'comment_id', NEW.comment_id)
    );
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS mentions_post_comment_trg ON public.posts_comments;
CREATE TRIGGER mentions_post_comment_trg
    AFTER INSERT ON public.posts_comments
    FOR EACH ROW EXECUTE FUNCTION public._trg_mentions_post_comment();

CREATE OR REPLACE FUNCTION public._trg_mentions_whisper_comment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    PERFORM _notify_mentions(
        NEW.author_id, NEW.content, 'whisper_comment', NEW.comment_id,
        jsonb_build_object('whisper_id', NEW.whisper_id,
                           'comment_id', NEW.comment_id)
    );
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS mentions_whisper_comment_trg ON public.whisper_comments;
CREATE TRIGGER mentions_whisper_comment_trg
    AFTER INSERT ON public.whisper_comments
    FOR EACH ROW EXECUTE FUNCTION public._trg_mentions_whisper_comment();
