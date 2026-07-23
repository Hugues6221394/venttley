-- 0113_notification_engine.sql
--
-- Production notification engine — Instagram-style social notifications.
--
--  * Expands the notifications.kind CHECK. The 0001 list never included
--    'tribe_invite', so the 0011 invite trigger has been violating the
--    constraint and ABORTING every tribe invite that fired it.
--  * Adds actor / subject / grouping columns.
--  * Grouped writer _notify(): likes collapse within a 5-minute window,
--    comments within 2 minutes ("A, B and 3 others liked your vent");
--    friend requests and tribe invites never group.
--  * Triggers: post likes, post comments (incl. reply-to-comment),
--    comment likes, whisper reactions, whisper comments,
--    friend requests, friend accepted.
--  * unread_notification_count() RPC for the bell badge.
--  * notifications joins the supabase_realtime publication (RLS: owner).

-- ---------------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------------
ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_kind_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_kind_check CHECK (kind::text IN (
    'comment_reply', 'post_like', 'comment_like', 'mention',
    'new_follower', 'friend_request', 'friend_accepted',
    'message_request', 'message_accepted',
    'tribe_prompt', 'tribe_invite',
    'whisper_reply', 'whisper_reaction',
    'moderation_action', 'admin_broadcast', 'system'
));

ALTER TABLE public.notifications
    ADD COLUMN IF NOT EXISTS actor_id     UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS subject_type TEXT,
    ADD COLUMN IF NOT EXISTS subject_id   UUID,
    ADD COLUMN IF NOT EXISTS group_count  INT  NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS updated_at   TIMESTAMPTZ NOT NULL DEFAULT now();

-- Grouping lookup: one unread bucket per (owner, kind, subject).
CREATE INDEX IF NOT EXISTS idx_notifications_group
    ON public.notifications (user_id, kind, subject_id, updated_at DESC)
    WHERE NOT is_read;

-- ---------------------------------------------------------------------------
-- 2. Grouped writer
-- ---------------------------------------------------------------------------
-- Collapses repeat events on the same subject into one unread row within
-- p_window ("Midnight Soul, Quiet Storm and 18 others liked your vent").
-- p_window = NULL disables grouping (friend requests, invites).
CREATE OR REPLACE FUNCTION public._notify(
    p_user         UUID,          -- notification owner
    p_actor        UUID,          -- who did the thing (skips self-notify)
    p_kind         TEXT,
    p_subject_type TEXT,
    p_subject_id   UUID,
    p_action       TEXT,          -- e.g. 'liked your vent'
    p_preview      TEXT DEFAULT NULL,
    p_window       INTERVAL DEFAULT NULL,
    p_extra        JSONB DEFAULT '{}'::jsonb
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actor_name TEXT;
    v_row        notifications%ROWTYPE;
    v_actors     JSONB;
    v_names      TEXT;
    v_count      INT;
BEGIN
    IF p_user IS NULL OR p_user = p_actor THEN RETURN; END IF;

    SELECT COALESCE(anonymous_pseudonym, 'Someone') INTO v_actor_name
      FROM users WHERE user_id = p_actor;
    v_actor_name := COALESCE(v_actor_name, 'Someone');

    IF p_window IS NOT NULL THEN
        SELECT * INTO v_row
          FROM notifications
         WHERE user_id = p_user
           AND kind = p_kind
           AND subject_id = p_subject_id
           AND NOT is_read
           AND updated_at > now() - p_window
         ORDER BY updated_at DESC
         LIMIT 1
         FOR UPDATE;

        IF FOUND THEN
            -- Keep the newest 3 distinct actor names for the grouped body.
            v_actors := COALESCE(v_row.payload->'actors', '[]'::jsonb);
            IF NOT v_actors @> to_jsonb(v_actor_name) THEN
                v_actors := to_jsonb(v_actor_name) || v_actors;
            END IF;
            v_actors := (
                SELECT COALESCE(jsonb_agg(x), '[]'::jsonb)
                  FROM (SELECT value AS x FROM jsonb_array_elements(v_actors) LIMIT 3) s
            );
            v_count := v_row.group_count + 1;
            v_names := (
                SELECT string_agg(value #>> '{}', ', ')
                  FROM jsonb_array_elements(v_actors)
            );
            UPDATE notifications
               SET group_count = v_count,
                   actor_id    = p_actor,
                   updated_at  = now(),
                   payload     = v_row.payload || p_extra || jsonb_build_object(
                       'actors', v_actors,
                       'title',  CASE
                                     WHEN v_count > jsonb_array_length(v_actors) THEN
                                         v_names || ' and ' ||
                                         (v_count - jsonb_array_length(v_actors))::TEXT ||
                                         ' others'
                                     ELSE v_names
                                 END,
                       'body',   p_action ||
                                 COALESCE(' "' || left(p_preview, 60) || '"', ''),
                       'count',  v_count
                   )
             WHERE notification_id = v_row.notification_id;
            RETURN;
        END IF;
    END IF;

    INSERT INTO notifications (user_id, kind, actor_id, subject_type, subject_id, payload)
    VALUES (
        p_user, p_kind, p_actor, p_subject_type, p_subject_id,
        p_extra || jsonb_build_object(
            'title',  v_actor_name,
            'body',   p_action || COALESCE(' "' || left(p_preview, 60) || '"', ''),
            'actors', jsonb_build_array(v_actor_name),
            'count',  1
        )
    );
END $$;

-- ---------------------------------------------------------------------------
-- 3. Triggers
-- ---------------------------------------------------------------------------

-- Post likes → 5-minute grouping window.
CREATE OR REPLACE FUNCTION public._trg_notify_post_like()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_author  UUID;
    v_preview TEXT;
BEGIN
    SELECT author_id, content INTO v_author, v_preview
      FROM posts WHERE post_id = NEW.post_id AND deleted_at IS NULL;
    PERFORM _notify(
        v_author, NEW.user_id, 'post_like', 'post', NEW.post_id,
        'liked your vent', v_preview, INTERVAL '5 minutes',
        jsonb_build_object('post_id', NEW.post_id)
    );
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notify_post_like_trg ON public.post_likes;
CREATE TRIGGER notify_post_like_trg
    AFTER INSERT ON public.post_likes
    FOR EACH ROW EXECUTE FUNCTION public._trg_notify_post_like();

-- Post comments → 2-minute grouping window; replies also ping the
-- parent-comment author.
CREATE OR REPLACE FUNCTION public._trg_notify_post_comment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_post_author   UUID;
    v_preview       TEXT;
    v_parent_author UUID;
BEGIN
    SELECT author_id, content INTO v_post_author, v_preview
      FROM posts WHERE post_id = NEW.post_id AND deleted_at IS NULL;
    PERFORM _notify(
        v_post_author, NEW.author_id, 'comment_reply', 'post', NEW.post_id,
        'replied to your vent', v_preview, INTERVAL '2 minutes',
        jsonb_build_object('post_id', NEW.post_id)
    );
    IF NEW.parent_id IS NOT NULL THEN
        SELECT author_id INTO v_parent_author
          FROM posts_comments WHERE comment_id = NEW.parent_id;
        IF v_parent_author IS DISTINCT FROM v_post_author THEN
            PERFORM _notify(
                v_parent_author, NEW.author_id, 'comment_reply', 'comment', NEW.parent_id,
                'replied to your comment', left(NEW.content, 60), INTERVAL '2 minutes',
                jsonb_build_object('post_id', NEW.post_id, 'comment_id', NEW.parent_id)
            );
        END IF;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notify_post_comment_trg ON public.posts_comments;
CREATE TRIGGER notify_post_comment_trg
    AFTER INSERT ON public.posts_comments
    FOR EACH ROW EXECUTE FUNCTION public._trg_notify_post_comment();

-- Comment likes → 5-minute window.
CREATE OR REPLACE FUNCTION public._trg_notify_comment_like()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_author  UUID;
    v_preview TEXT;
    v_post    UUID;
BEGIN
    SELECT author_id, content, post_id INTO v_author, v_preview, v_post
      FROM posts_comments WHERE comment_id = NEW.comment_id;
    PERFORM _notify(
        v_author, NEW.user_id, 'comment_like', 'comment', NEW.comment_id,
        'liked your comment', v_preview, INTERVAL '5 minutes',
        jsonb_build_object('post_id', v_post, 'comment_id', NEW.comment_id)
    );
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notify_comment_like_trg ON public.comment_likes;
CREATE TRIGGER notify_comment_like_trg
    AFTER INSERT ON public.comment_likes
    FOR EACH ROW EXECUTE FUNCTION public._trg_notify_comment_like();

-- Whisper reactions → 5-minute window.
CREATE OR REPLACE FUNCTION public._trg_notify_whisper_reaction()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_author  UUID;
    v_preview TEXT;
BEGIN
    SELECT author_id, title INTO v_author, v_preview
      FROM whispers WHERE whisper_id = NEW.whisper_id AND deleted_at IS NULL;
    PERFORM _notify(
        v_author, NEW.user_id, 'whisper_reaction', 'whisper', NEW.whisper_id,
        'reacted to your whisper', v_preview, INTERVAL '5 minutes',
        jsonb_build_object('whisper_id', NEW.whisper_id)
    );
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notify_whisper_reaction_trg ON public.whisper_reactions;
CREATE TRIGGER notify_whisper_reaction_trg
    AFTER INSERT ON public.whisper_reactions
    FOR EACH ROW EXECUTE FUNCTION public._trg_notify_whisper_reaction();

-- Whisper comments → 2-minute window.
CREATE OR REPLACE FUNCTION public._trg_notify_whisper_comment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_author  UUID;
    v_preview TEXT;
BEGIN
    SELECT author_id, title INTO v_author, v_preview
      FROM whispers WHERE whisper_id = NEW.whisper_id AND deleted_at IS NULL;
    PERFORM _notify(
        v_author, NEW.author_id, 'whisper_reply', 'whisper', NEW.whisper_id,
        'replied to your whisper', v_preview, INTERVAL '2 minutes',
        jsonb_build_object('whisper_id', NEW.whisper_id)
    );
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notify_whisper_comment_trg ON public.whisper_comments;
CREATE TRIGGER notify_whisper_comment_trg
    AFTER INSERT ON public.whisper_comments
    FOR EACH ROW EXECUTE FUNCTION public._trg_notify_whisper_comment();

-- Friend requests / accepts — never grouped.
CREATE OR REPLACE FUNCTION public._trg_notify_friendship()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_target UUID;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.status = 'pending' THEN
        v_target := CASE WHEN NEW.requested_by = NEW.user_a
                         THEN NEW.user_b ELSE NEW.user_a END;
        PERFORM _notify(
            v_target, NEW.requested_by, 'friend_request', 'friendship',
            NEW.friendship_id, 'sent you a friend request', NULL, NULL,
            jsonb_build_object('friendship_id', NEW.friendship_id,
                               'requester_id', NEW.requested_by)
        );
    ELSIF TG_OP = 'UPDATE'
          AND OLD.status = 'pending' AND NEW.status = 'accepted' THEN
        v_target := CASE WHEN NEW.requested_by = NEW.user_a
                         THEN NEW.user_b ELSE NEW.user_a END;
        PERFORM _notify(
            NEW.requested_by, v_target, 'friend_accepted', 'friendship',
            NEW.friendship_id, 'accepted your friend request', NULL, NULL,
            jsonb_build_object('friendship_id', NEW.friendship_id,
                               'friend_id', v_target)
        );
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notify_friendship_trg ON public.friendships;
CREATE TRIGGER notify_friendship_trg
    AFTER INSERT OR UPDATE OF status ON public.friendships
    FOR EACH ROW EXECUTE FUNCTION public._trg_notify_friendship();

-- ---------------------------------------------------------------------------
-- 4. Bell badge
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.unread_notification_count()
RETURNS INT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    SELECT COUNT(*)::INT FROM notifications
     WHERE user_id = auth.uid() AND NOT is_read;
$$;

REVOKE ALL ON FUNCTION public.unread_notification_count() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unread_notification_count() TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Realtime delivery (RLS "notifications owner" scopes events per user)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
