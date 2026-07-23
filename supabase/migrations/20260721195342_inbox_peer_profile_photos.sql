-- Surface the other participant's uploaded profile photo in direct-message
-- inbox rows. Keep the field nullable so users without a photo continue to
-- receive the deterministic avatar-seed fallback in the client.
CREATE OR REPLACE VIEW public.inbox_rooms
WITH (security_invoker = true) AS
SELECT
  r.room_id,
  r.initiated_by,
  r.received_by,
  r.request_preview,
  r.room_status,
  r.created_at,
  r.updated_at,
  CASE WHEN r.room_kind = 'group' THEN NULL::UUID
       WHEN r.initiated_by = auth.uid() THEN r.received_by
       ELSE r.initiated_by END AS peer_id,
  CASE WHEN r.room_kind = 'group' THEN r.title
       WHEN r.initiated_by = auth.uid() THEN peer_recv.anonymous_pseudonym
       ELSE peer_init.anonymous_pseudonym END AS peer_pseudonym,
  CASE WHEN r.room_kind = 'group' THEN 'group-' || r.room_id::TEXT
       WHEN r.initiated_by = auth.uid() THEN peer_recv.avatar_seed
       ELSE peer_init.avatar_seed END AS peer_avatar_seed,
  CASE WHEN r.room_kind = 'group' THEN r.created_by = auth.uid()
       ELSE r.initiated_by = auth.uid() END AS initiated_by_me,
  r.room_kind = 'group' AS is_group,
  CASE WHEN r.room_kind = 'group' THEN r.title END AS group_title,
  CASE WHEN r.room_kind = 'group' THEN r.group_avatar_path END
    AS group_avatar_path,
  CASE WHEN r.room_kind = 'group' THEN r.invite_token END
    AS group_invite_token,
  CASE WHEN r.room_kind = 'group' THEN r.invite_enabled END
    AS group_invite_enabled,
  CASE WHEN r.room_kind = 'group' THEN r.allow_member_invites END
    AS group_allow_member_invites,
  CASE WHEN r.room_kind = 'group' THEN r.created_by = auth.uid()
       ELSE FALSE END AS is_group_owner,
  CASE WHEN r.room_kind = 'group' THEN (
    SELECT count(*)::INT FROM public.chat_room_members gm
     WHERE gm.room_id = r.room_id AND gm.left_at IS NULL
  ) ELSE 2 END AS member_count,
  COALESCE(lm.unread_count, 0)::INT AS unread_count,
  lm.last_message_preview,
  lm.last_message_at,
  COALESCE(lm.last_own_message_read, FALSE) AS last_own_message_read,
  COALESCE(lm.last_message_at, r.updated_at, r.created_at) AS sort_activity_at,
  CASE WHEN r.room_kind = 'group' THEN NULL::TEXT
       WHEN r.initiated_by = auth.uid()
         THEN NULLIF(btrim(peer_recv.profile_photo_url), '')
       ELSE NULLIF(btrim(peer_init.profile_photo_url), '')
       END AS peer_profile_photo_url
FROM public.chat_rooms r
LEFT JOIN public.users peer_init ON peer_init.user_id = r.initiated_by
LEFT JOIN public.users peer_recv ON peer_recv.user_id = r.received_by
LEFT JOIN LATERAL (
  SELECT
    (SELECT count(*)::INT FROM public.chat_messages m
      WHERE m.room_id = r.room_id
        AND m.sender_id IS DISTINCT FROM auth.uid()
        AND m.deleted_at IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.chat_message_receipts rr
           WHERE rr.message_id = m.message_id
             AND rr.user_id = auth.uid() AND rr.read_at IS NOT NULL
        )) AS unread_count,
    (SELECT COALESCE(
       NULLIF(left(m.encrypted_payload, 280), ''),
       CASE m.attached_media_type WHEN 'audio' THEN 'Voice note'
            WHEN 'image' THEN 'Photo' ELSE NULL END
     ) FROM public.chat_messages m
      WHERE m.room_id = r.room_id AND m.deleted_at IS NULL
      ORDER BY m.created_at DESC LIMIT 1) AS last_message_preview,
    (SELECT m.created_at FROM public.chat_messages m
      WHERE m.room_id = r.room_id AND m.deleted_at IS NULL
      ORDER BY m.created_at DESC LIMIT 1) AS last_message_at,
    (SELECT EXISTS (
       SELECT 1 FROM public.chat_message_receipts rr
        WHERE rr.message_id = m.message_id AND rr.read_at IS NOT NULL
     ) FROM public.chat_messages m
      WHERE m.room_id = r.room_id AND m.sender_id = auth.uid()
        AND m.deleted_at IS NULL
      ORDER BY m.created_at DESC LIMIT 1) AS last_own_message_read
) lm ON TRUE;

REVOKE ALL ON public.inbox_rooms FROM PUBLIC, anon;
GRANT SELECT ON public.inbox_rooms TO authenticated;

COMMENT ON COLUMN public.inbox_rooms.peer_profile_photo_url IS
  'Uploaded photo for the other direct-message participant; null for groups or users without a photo.';

NOTIFY pgrst, 'reload schema';
