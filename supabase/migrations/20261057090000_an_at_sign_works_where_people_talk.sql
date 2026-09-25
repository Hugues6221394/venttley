-- @ works where people actually talk.
--
-- Asked for directly: "ensure the @ is for tagging people on vents, 24 hr
-- stories, comments, in spaces, group chats, I mean everywhere where a tag can
-- be useful."
--
-- Where it already worked: vents, stories and space posts (all three are rows
-- in `posts`, so one trigger covers them), post comments, and whisper
-- comments. Where it did not: tribe group chats and the group chats in the
-- inbox — the two places where people are mid-conversation and most likely to
-- want somebody pulled in.
--
-- The other half of this migration is a hole that only becomes visible once
-- mentions reach private rooms, and which is already open on the public side.
-- _notify_mentions sends the first sixty characters of the content to anybody
-- whose handle matches:
--
--   PERFORM public._notify(v_target, ..., left(p_content, 60), ...)
--
-- with no check that the person can see the thing they were named in. Mention
-- a stranger in a private tribe's post today and they get sixty characters of
-- it. Do the same in a group chat and it would be sixty characters of a
-- private conversation. So a mention is now only delivered to somebody the
-- content is already visible to, and where it is not, the mention row is still
-- recorded — the tag renders for the people who can see it — but nobody is
-- told.

-- Two more kinds of thing a mention can live in.
ALTER TABLE private.content_mentions
  DROP CONSTRAINT IF EXISTS content_mentions_source_kind_check;

ALTER TABLE private.content_mentions
  ADD CONSTRAINT content_mentions_source_kind_check
  CHECK (source_kind = ANY (ARRAY[
    'post', 'comment', 'whisper_comment', 'tribe_message', 'group_message'
  ]));

-- The old five-argument form goes, rather than sitting beside the new one: two
-- overloads that differ only by a defaulted parameter make every five-argument
-- call ambiguous.
DROP FUNCTION IF EXISTS public._notify_mentions(UUID, TEXT, TEXT, UUID, JSONB);

CREATE OR REPLACE FUNCTION public._notify_mentions(
  p_actor        UUID,
  p_content      TEXT,
  p_subject_type TEXT,
  p_subject_id   UUID,
  p_extra        JSONB,
  -- The room or tribe the content lives in, for the kinds that have one.
  -- Null means "anybody can see this", which is true of a whisper comment and
  -- of a post outside a tribe.
  p_audience_id  UUID DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_handle   TEXT;
  v_target   UUID;
  v_previous UUID[];
  v_can_see  BOOLEAN;
BEGIN
  IF p_subject_type NOT IN (
       'post', 'comment', 'whisper_comment', 'tribe_message', 'group_message'
     ) THEN
    RAISE EXCEPTION 'unsupported mention subject';
  END IF;

  SELECT array_agg(cm.mentioned_user_id)
    INTO v_previous
    FROM private.content_mentions AS cm
   WHERE cm.source_kind = p_subject_type AND cm.source_id = p_subject_id;

  DELETE FROM private.content_mentions AS cm
   WHERE cm.source_kind = p_subject_type AND cm.source_id = p_subject_id;

  IF p_content IS NULL THEN RETURN; END IF;

  FOR v_handle IN
    SELECT DISTINCT lower(m[1])
      FROM pg_catalog.regexp_matches(p_content, '@([A-Za-z0-9_.-]{2,32})', 'g') AS m
     LIMIT 10
  LOOP
    v_target := NULL;
    SELECT u.user_id INTO v_target
      FROM public.users AS u
     WHERE u.username_normalized = v_handle AND u.deactivated_at IS NULL
     LIMIT 1;

    IF v_target IS NOT NULL THEN
      INSERT INTO private.content_mentions (
        source_kind, source_id, mentioned_user_id, handle_snapshot
      ) VALUES (p_subject_type, p_subject_id, v_target, v_handle)
      ON CONFLICT (source_kind, source_id, mentioned_user_id)
      DO UPDATE SET handle_snapshot = EXCLUDED.handle_snapshot;

      -- Can this person see what they were named in?
      --
      -- Naming somebody is not a way to send them content they are not in the
      -- room for. Where they cannot see it the tag is still recorded, so it
      -- renders for everyone who can, and no notification goes out.
      v_can_see := CASE p_subject_type
        WHEN 'tribe_message' THEN EXISTS (
          SELECT 1 FROM public.tribe_members tm
           WHERE tm.tribe_id = p_audience_id AND tm.user_id = v_target)
        WHEN 'group_message' THEN EXISTS (
          SELECT 1 FROM public.chat_room_members cm
           WHERE cm.room_id = p_audience_id
             AND cm.user_id = v_target
             AND cm.left_at IS NULL)
        WHEN 'post' THEN p_audience_id IS NULL OR EXISTS (
          SELECT 1 FROM public.tribes t
           WHERE t.tribe_id = p_audience_id
             AND (t.visibility <> 'private'
                  OR EXISTS (SELECT 1 FROM public.tribe_members tm
                              WHERE tm.tribe_id = t.tribe_id
                                AND tm.user_id = v_target)))
        WHEN 'comment' THEN p_audience_id IS NULL OR EXISTS (
          SELECT 1 FROM public.tribes t
           WHERE t.tribe_id = p_audience_id
             AND (t.visibility <> 'private'
                  OR EXISTS (SELECT 1 FROM public.tribe_members tm
                              WHERE tm.tribe_id = t.tribe_id
                                AND tm.user_id = v_target)))
        ELSE TRUE
      END;

      IF v_can_see AND (v_previous IS NULL OR NOT (v_target = ANY(v_previous)))
      THEN
        PERFORM public._notify(
          v_target, p_actor, 'mention', p_subject_type, p_subject_id,
          'mentioned you', pg_catalog.left(p_content, 60), NULL,
          COALESCE(p_extra, '{}'::jsonb)
        );
      END IF;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION
  public._notify_mentions(UUID, TEXT, TEXT, UUID, JSONB, UUID)
  FROM PUBLIC, anon, authenticated;
-- service_role keeps it, as it did before: 0009 asserts exactly this split —
-- no client may reach the helper, and operational access survives.
GRANT EXECUTE ON FUNCTION
  public._notify_mentions(UUID, TEXT, TEXT, UUID, JSONB, UUID)
  TO service_role;

-- The existing four, now passing the room they were written in.
CREATE OR REPLACE FUNCTION public._trg_mentions_post()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._notify_mentions(
    NEW.author_id, NEW.content, 'post', NEW.post_id,
    jsonb_build_object('post_id', NEW.post_id),
    NEW.tribe_id
  );
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._trg_mentions_post_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tribe UUID;
BEGIN
  SELECT p.tribe_id INTO v_tribe
    FROM public.posts p WHERE p.post_id = NEW.post_id;

  PERFORM public._notify_mentions(
    NEW.author_id, NEW.content, 'comment', NEW.comment_id,
    jsonb_build_object('post_id', NEW.post_id, 'comment_id', NEW.comment_id),
    v_tribe
  );
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._trg_mentions_whisper_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public._notify_mentions(
    NEW.author_id, NEW.content, 'whisper_comment', NEW.comment_id,
    jsonb_build_object('whisper_id', NEW.whisper_id, 'comment_id', NEW.comment_id),
    NULL
  );
  RETURN NEW;
END;
$$;

-- Tribe group chat, which is where most of the tagging will happen.
CREATE OR REPLACE FUNCTION public._trg_mentions_tribe_message()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_slug TEXT;
BEGIN
  SELECT t.slug INTO v_slug
    FROM public.tribes t WHERE t.tribe_id = NEW.tribe_id;

  PERFORM public._notify_mentions(
    NEW.sender_id, NEW.content, 'tribe_message', NEW.message_id,
    jsonb_build_object(
      'tribe_id', NEW.tribe_id,
      'tribe_slug', v_slug,
      'message_id', NEW.message_id
    ),
    NEW.tribe_id
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS mentions_tribe_message_trg ON public.tribe_messages;
CREATE TRIGGER mentions_tribe_message_trg
AFTER INSERT OR UPDATE OF content ON public.tribe_messages
FOR EACH ROW EXECUTE FUNCTION public._trg_mentions_tribe_message();

CREATE OR REPLACE FUNCTION private.clear_tribe_message_mentions()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  DELETE FROM private.content_mentions
   WHERE source_kind = 'tribe_message' AND source_id = OLD.message_id;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS clear_tribe_message_mentions_trg ON public.tribe_messages;
CREATE TRIGGER clear_tribe_message_mentions_trg
AFTER DELETE ON public.tribe_messages
FOR EACH ROW EXECUTE FUNCTION private.clear_tribe_message_mentions();

-- Group chats in the inbox. Groups only: in a two-person thread the other
-- person is already being told about the message itself, and a second
-- notification saying the same thing with their own name in it is noise.
CREATE OR REPLACE FUNCTION public._trg_mentions_group_message()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_is_group BOOLEAN;
BEGIN
  SELECT r.room_kind = 'group' INTO v_is_group
    FROM public.chat_rooms r WHERE r.room_id = NEW.room_id;

  IF NOT COALESCE(v_is_group, FALSE) THEN RETURN NEW; END IF;

  PERFORM public._notify_mentions(
    NEW.sender_id, NEW.encrypted_payload, 'group_message', NEW.message_id,
    jsonb_build_object('room_id', NEW.room_id, 'message_id', NEW.message_id),
    NEW.room_id
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS mentions_group_message_trg ON public.chat_messages;
CREATE TRIGGER mentions_group_message_trg
AFTER INSERT OR UPDATE OF encrypted_payload ON public.chat_messages
FOR EACH ROW EXECUTE FUNCTION public._trg_mentions_group_message();

CREATE OR REPLACE FUNCTION private.clear_group_message_mentions()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  DELETE FROM private.content_mentions
   WHERE source_kind = 'group_message' AND source_id = OLD.message_id;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS clear_group_message_mentions_trg ON public.chat_messages;
CREATE TRIGGER clear_group_message_mentions_trg
AFTER DELETE ON public.chat_messages
FOR EACH ROW EXECUTE FUNCTION private.clear_group_message_mentions();

SELECT public.record_migration(
  '20261057090000', 'an_at_sign_works_where_people_talk'
);

NOTIFY pgrst, 'reload schema';
