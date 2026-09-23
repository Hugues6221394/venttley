-- Activity status and read receipts, as settings that do something.
--
-- Both were half-built. users.show_last_seen has existed since 0114 and
-- peer_presence honours it — there has never been a way to change it. Read
-- receipts had no preference at all: every read was published to the sender,
-- with no opt-out anywhere.
--
-- The hard part is that switching receipts off must not break unread counts.
-- They are two different questions asked of the same fact: "have I read this"
-- drives my own badge and must keep working, "has the other person read mine"
-- is the courtesy being withdrawn. So the receipt row is still written — the
-- reader's own unread count depends on it — and what changes is who may learn
-- from it.
--
-- Reciprocal, deliberately, and the way every messenger does it: switching
-- your receipts off also stops you seeing other people's. Otherwise it is a
-- setting for taking without giving, and it is the one thing users reliably
-- expect here.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS show_read_receipts BOOLEAN NOT NULL DEFAULT TRUE;

-- Whether a read by p_reader may be shown to the person asking.
--
-- Both halves: the reader has to be publishing receipts, and the viewer has
-- to be publishing their own to be allowed to see anyone else's.
CREATE OR REPLACE FUNCTION private.read_receipts_visible(p_reader UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
           (SELECT u.show_read_receipts FROM public.users u
             WHERE u.user_id = p_reader), TRUE)
     AND COALESCE(
           (SELECT v.show_read_receipts FROM public.users v
             WHERE v.user_id = (SELECT auth.uid())), TRUE);
$$;

GRANT EXECUTE ON FUNCTION private.read_receipts_visible(UUID) TO authenticated;

-- One call for both preferences. NULL means "leave this one alone", so the
-- client can flip either switch without having to send the other and risk
-- writing back a stale value.
CREATE OR REPLACE FUNCTION public.set_presence_preferences(
  p_show_last_seen     BOOLEAN DEFAULT NULL,
  p_show_read_receipts BOOLEAN DEFAULT NULL
) RETURNS TABLE (show_last_seen BOOLEAN, show_read_receipts BOOLEAN)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid());
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not_signed_in' USING ERRCODE = '42501';
  END IF;

  UPDATE public.users u
     SET show_last_seen     = COALESCE(p_show_last_seen, u.show_last_seen),
         show_read_receipts = COALESCE(p_show_read_receipts, u.show_read_receipts)
   WHERE u.user_id = v_me;

  RETURN QUERY
    SELECT u.show_last_seen, u.show_read_receipts
      FROM public.users u WHERE u.user_id = v_me;
END $$;

REVOKE ALL ON FUNCTION public.set_presence_preferences(BOOLEAN, BOOLEAN)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_presence_preferences(BOOLEAN, BOOLEAN)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.my_presence_preferences()
RETURNS TABLE (show_last_seen BOOLEAN, show_read_receipts BOOLEAN)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT u.show_last_seen, u.show_read_receipts
    FROM public.users u WHERE u.user_id = (SELECT auth.uid());
$$;

REVOKE ALL ON FUNCTION public.my_presence_preferences() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_presence_preferences() TO authenticated;

-- The sender-visible stamp on the message itself. The receipt row is still
-- written above it, so the reader's unread count is unaffected; this is the
-- field a chat bubble turns blue on.
CREATE OR REPLACE FUNCTION public.mark_chat_room_read(p_room_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me    UUID := (SELECT auth.uid());
  v_count INT;
  v_show  BOOLEAN;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'not a participant';
  END IF;

  SELECT COALESCE(u.show_read_receipts, TRUE) INTO v_show
    FROM public.users u WHERE u.user_id = v_me;

  WITH inserted AS (
    INSERT INTO public.chat_message_receipts (
      message_id, user_id, delivered_at, read_at
    )
    SELECT m.message_id, v_me, now(), now()
      FROM public.chat_messages m
     WHERE m.room_id = p_room_id AND m.sender_id <> v_me
    ON CONFLICT (message_id, user_id) DO UPDATE
      SET delivered_at = COALESCE(
            chat_message_receipts.delivered_at, EXCLUDED.delivered_at
          ),
          read_at = COALESCE(chat_message_receipts.read_at, EXCLUDED.read_at)
      WHERE chat_message_receipts.read_at IS NULL
    RETURNING message_id
  ) SELECT count(*)::INT INTO v_count FROM inserted;

  -- Delivery is not a courtesy — it says the message arrived, not that it was
  -- read — so it is stamped either way. Only read_at waits on consent.
  UPDATE public.chat_messages
     SET delivered_at = COALESCE(delivered_at, now()),
         read_at = CASE WHEN v_show THEN COALESCE(read_at, now()) ELSE read_at END
   WHERE room_id = p_room_id AND sender_id <> v_me;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.mark_chat_room_read(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_chat_room_read(UUID) TO authenticated;

-- inbox_rooms.last_own_message_read is the other place a read escapes: it
-- reports whether the peer has read your last message, straight from the
-- receipt table, which read_at on the message does not gate.
CREATE OR REPLACE VIEW public.inbox_rooms
WITH (security_invoker = true) AS
SELECT r.room_id,
    r.initiated_by,
    r.received_by,
    r.request_preview,
    r.room_status,
    r.created_at,
    r.updated_at,
        CASE
            WHEN r.room_kind = 'group'::text THEN NULL::uuid
            WHEN r.initiated_by = auth.uid() THEN r.received_by
            ELSE r.initiated_by
        END AS peer_id,
        CASE
            WHEN r.room_kind = 'group'::text THEN r.title::character varying
            WHEN r.initiated_by = auth.uid() THEN peer_recv.anonymous_pseudonym
            ELSE peer_init.anonymous_pseudonym
        END AS peer_pseudonym,
        CASE
            WHEN r.room_kind = 'group'::text THEN ('group-'::text || r.room_id::text)::character varying
            WHEN r.initiated_by = auth.uid() THEN peer_recv.avatar_seed
            ELSE peer_init.avatar_seed
        END AS peer_avatar_seed,
        CASE
            WHEN r.room_kind = 'group'::text THEN r.created_by = auth.uid()
            ELSE r.initiated_by = auth.uid()
        END AS initiated_by_me,
    r.room_kind = 'group'::text AS is_group,
        CASE
            WHEN r.room_kind = 'group'::text THEN r.title
            ELSE NULL::text
        END AS group_title,
        CASE
            WHEN r.room_kind = 'group'::text THEN r.group_avatar_path
            ELSE NULL::text
        END AS group_avatar_path,
        CASE
            WHEN r.room_kind = 'group'::text THEN r.invite_token
            ELSE NULL::uuid
        END AS group_invite_token,
        CASE
            WHEN r.room_kind = 'group'::text THEN r.invite_enabled
            ELSE NULL::boolean
        END AS group_invite_enabled,
        CASE
            WHEN r.room_kind = 'group'::text THEN r.allow_member_invites
            ELSE NULL::boolean
        END AS group_allow_member_invites,
        CASE
            WHEN r.room_kind = 'group'::text THEN r.created_by = auth.uid()
            ELSE false
        END AS is_group_owner,
        CASE
            WHEN r.room_kind = 'group'::text THEN ( SELECT count(*)::integer AS count
               FROM chat_room_members gm
              WHERE gm.room_id = r.room_id AND gm.left_at IS NULL)
            ELSE 2
        END AS member_count,
    COALESCE(lm.unread_count, 0) AS unread_count,
    lm.last_message_preview,
    lm.last_message_at,
    COALESCE(lm.last_own_message_read, false) AS last_own_message_read,
    COALESCE(lm.last_message_at, r.updated_at, r.created_at) AS sort_activity_at,
        CASE
            WHEN r.room_kind = 'group'::text THEN NULL::text
            WHEN r.initiated_by = auth.uid() THEN NULLIF(btrim(peer_recv.profile_photo_url), ''::text)
            ELSE NULLIF(btrim(peer_init.profile_photo_url), ''::text)
        END AS peer_profile_photo_url
   FROM chat_rooms r
     LEFT JOIN users peer_init ON peer_init.user_id = r.initiated_by
     LEFT JOIN users peer_recv ON peer_recv.user_id = r.received_by
     LEFT JOIN LATERAL ( SELECT ( SELECT count(*)::integer AS count
                   FROM chat_messages m
                  WHERE m.room_id = r.room_id AND m.sender_id IS DISTINCT FROM auth.uid() AND m.deleted_at IS NULL AND NOT (EXISTS ( SELECT 1
                           FROM chat_message_receipts rr
                          WHERE rr.message_id = m.message_id AND rr.user_id = auth.uid() AND rr.read_at IS NOT NULL))) AS unread_count,
            ( SELECT COALESCE(NULLIF("left"(m.encrypted_payload, 280), ''::text),
                        CASE m.attached_media_type
                            WHEN 'audio'::text THEN 'Voice note'::text
                            WHEN 'image'::text THEN 'Photo'::text
                            ELSE NULL::text
                        END) AS "coalesce"
                   FROM chat_messages m
                  WHERE m.room_id = r.room_id AND m.deleted_at IS NULL
                  ORDER BY m.created_at DESC
                 LIMIT 1) AS last_message_preview,
            ( SELECT m.created_at
                   FROM chat_messages m
                  WHERE m.room_id = r.room_id AND m.deleted_at IS NULL
                  ORDER BY m.created_at DESC
                 LIMIT 1) AS last_message_at,
            ( SELECT (EXISTS ( SELECT 1
                           FROM chat_message_receipts rr
                          WHERE rr.message_id = m.message_id AND rr.read_at IS NOT NULL
                            AND private.read_receipts_visible(rr.user_id))) AS "exists"
                   FROM chat_messages m
                  WHERE m.room_id = r.room_id AND m.sender_id = auth.uid() AND m.deleted_at IS NULL
                  ORDER BY m.created_at DESC
                 LIMIT 1) AS last_own_message_read) lm ON true;

GRANT SELECT ON public.inbox_rooms TO authenticated;

SELECT public.record_migration(
  '20261040090000', 'presence_and_receipt_preferences'
);

NOTIFY pgrst, 'reload schema';
