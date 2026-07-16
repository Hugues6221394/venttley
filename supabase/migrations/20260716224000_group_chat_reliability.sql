-- Named private group chats created from an existing one-to-one friendship.
-- The first production slice contains the creator and the friend whose chat
-- opened the flow. It deliberately reuses the mature DM transport, media,
-- reactions, receipts, moderation, and disappearing-message controls.

ALTER TABLE public.chat_rooms
  ADD COLUMN IF NOT EXISTS room_kind TEXT NOT NULL DEFAULT 'direct',
  ADD COLUMN IF NOT EXISTS title TEXT,
  ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES public.users(user_id)
    ON DELETE SET NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'chat_rooms_room_kind_check'
       AND conrelid = 'public.chat_rooms'::regclass
  ) THEN
    ALTER TABLE public.chat_rooms
      ADD CONSTRAINT chat_rooms_room_kind_check
      CHECK (room_kind IN ('direct', 'group'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'chat_rooms_group_title_check'
       AND conrelid = 'public.chat_rooms'::regclass
  ) THEN
    ALTER TABLE public.chat_rooms
      ADD CONSTRAINT chat_rooms_group_title_check
      CHECK (
        room_kind <> 'group'
        OR char_length(btrim(COALESCE(title, ''))) BETWEEN 2 AND 80
      );
  END IF;
END;
$$;

UPDATE public.chat_rooms
   SET created_by = initiated_by
 WHERE created_by IS NULL;

CREATE INDEX IF NOT EXISTS chat_rooms_kind_activity_idx
  ON public.chat_rooms (room_kind, updated_at DESC);

CREATE OR REPLACE FUNCTION public.create_group_chat(
  p_title TEXT,
  p_friend_id UUID
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_room_id UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF p_friend_id IS NULL OR p_friend_id = v_me THEN
    RAISE EXCEPTION 'invalid_friend';
  END IF;
  IF char_length(btrim(COALESCE(p_title, ''))) NOT BETWEEN 2 AND 80 THEN
    RAISE EXCEPTION 'group_title_length';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM public.friendships f
     WHERE f.status = 'accepted'
       AND v_me IN (f.user_a, f.user_b)
       AND p_friend_id IN (f.user_a, f.user_b)
  ) THEN
    RAISE EXCEPTION 'friends_only';
  END IF;
  IF public.has_block(v_me, p_friend_id) THEN
    RAISE EXCEPTION 'blocked';
  END IF;

  INSERT INTO public.chat_rooms (
    initiated_by,
    received_by,
    request_preview,
    room_status,
    room_kind,
    title,
    created_by,
    updated_at
  ) VALUES (
    v_me,
    p_friend_id,
    'Private group chat',
    'active',
    'group',
    btrim(p_title),
    v_me,
    now()
  ) RETURNING room_id INTO v_room_id;

  RETURN v_room_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_group_chat(TEXT, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_group_chat(TEXT, UUID)
  TO authenticated;

-- Preserve the enriched inbox contract while giving named rooms their own
-- display identity. Existing direct rows retain exactly the previous shape.
DROP VIEW IF EXISTS public.inbox_rooms;

CREATE VIEW public.inbox_rooms
WITH (security_invoker = true) AS
SELECT
    r.room_id,
    r.initiated_by,
    r.received_by,
    r.request_preview,
    r.room_status,
    r.created_at,
    r.updated_at,
    CASE
      WHEN r.room_kind = 'group' THEN NULL::UUID
      WHEN r.initiated_by = auth.uid() THEN r.received_by
      ELSE r.initiated_by
    END AS peer_id,
    CASE
      WHEN r.room_kind = 'group' THEN r.title
      WHEN r.initiated_by = auth.uid() THEN peer_recv.anonymous_pseudonym
      ELSE peer_init.anonymous_pseudonym
    END AS peer_pseudonym,
    CASE
      WHEN r.room_kind = 'group' THEN 'group-' || r.room_id::TEXT
      WHEN r.initiated_by = auth.uid() THEN peer_recv.avatar_seed
      ELSE peer_init.avatar_seed
    END AS peer_avatar_seed,
    CASE
      WHEN r.room_kind = 'group' THEN r.created_by = auth.uid()
      ELSE r.initiated_by = auth.uid()
    END AS initiated_by_me,
    r.room_kind = 'group' AS is_group,
    CASE WHEN r.room_kind = 'group' THEN r.title END AS group_title,
    2::INT AS member_count,
    COALESCE(lm.unread_count, 0)::INT AS unread_count,
    lm.last_message_preview,
    lm.last_message_at,
    COALESCE(lm.last_own_message_read, FALSE) AS last_own_message_read,
    COALESCE(lm.last_message_at, r.updated_at, r.created_at) AS sort_activity_at
FROM public.chat_rooms r
LEFT JOIN public.users peer_init ON peer_init.user_id = r.initiated_by
LEFT JOIN public.users peer_recv ON peer_recv.user_id = r.received_by
LEFT JOIN LATERAL (
    SELECT
        (
            SELECT count(*)::INT
              FROM public.chat_messages m
             WHERE m.room_id = r.room_id
               AND m.sender_id IS DISTINCT FROM auth.uid()
               AND m.read_at IS NULL
               AND m.deleted_at IS NULL
        ) AS unread_count,
        (
            SELECT COALESCE(
                       NULLIF(left(m.encrypted_payload, 280), ''),
                       CASE m.attached_media_type
                            WHEN 'audio' THEN 'Voice note'
                            WHEN 'image' THEN 'Photo'
                            ELSE NULL
                       END
                   )
              FROM public.chat_messages m
             WHERE m.room_id = r.room_id
               AND m.deleted_at IS NULL
             ORDER BY m.created_at DESC
             LIMIT 1
        ) AS last_message_preview,
        (
            SELECT m.created_at
              FROM public.chat_messages m
             WHERE m.room_id = r.room_id
               AND m.deleted_at IS NULL
             ORDER BY m.created_at DESC
             LIMIT 1
        ) AS last_message_at,
        (
            SELECT m.read_at IS NOT NULL
              FROM public.chat_messages m
             WHERE m.room_id = r.room_id
               AND m.sender_id = auth.uid()
               AND m.deleted_at IS NULL
             ORDER BY m.created_at DESC
             LIMIT 1
        ) AS last_own_message_read
) lm ON TRUE;

GRANT SELECT ON public.inbox_rooms TO anon, authenticated;
NOTIFY pgrst, 'reload schema';
