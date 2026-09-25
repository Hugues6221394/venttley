-- The inbox's "last message" is one message.
--
-- Found by a test that had been passing: 0055 sends two clips into a room and
-- checks the preview, and it reported the first one. Same transaction, so both
-- rows carry the same now(), and the view asks for the newest like this:
--
--   ORDER BY m.created_at DESC LIMIT 1
--
-- With no tie-break, "newest" among equal timestamps is whatever the plan
-- happens to hand back first. Three separate subqueries ask that question —
-- the preview, the time, and whether my last message was read — so they do not
-- only pick arbitrarily, they can pick *differently*: a row can show one
-- message's text beside another message's timestamp.
--
-- It is not only a test artefact. created_at is a timestamptz from now(), which
-- is the transaction's start time: anything that writes two messages in one
-- transaction gives them identical values, and two independent inserts in the
-- same millisecond do too. The symptom is an inbox row that shows the
-- second-to-last message, sometimes, and rights itself on the next send.
--
-- The fix is a tie-break on the primary key, and one lateral rather than three
-- subqueries, so the preview and the timestamp are read off the same row by
-- construction instead of by coincidence.
--
-- Column list and order are unchanged, which is what CREATE OR REPLACE VIEW
-- requires and what the callers of this view require.
--
-- The tie-break alone is not enough on its own, and it is worth being plain
-- about why: message_id is a random UUID, so ordering by it is stable for a
-- given set of rows but says nothing about which of two same-instant messages
-- was sent second. So the timestamps stop colliding as well — see the default
-- change below.

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
       WHEN r.room_kind = 'group' THEN NULL::uuid
       WHEN r.initiated_by = (SELECT auth.uid()) THEN r.received_by
       ELSE r.initiated_by
     END AS peer_id,
     CASE
       WHEN r.room_kind = 'group' THEN NULL::character varying
       WHEN r.initiated_by = (SELECT auth.uid()) THEN peer_recv.anonymous_pseudonym
       ELSE peer_init.anonymous_pseudonym
     END AS peer_pseudonym,
     CASE
       WHEN r.room_kind = 'group' THEN NULL::character varying
       WHEN r.initiated_by = (SELECT auth.uid()) THEN peer_recv.avatar_seed
       ELSE peer_init.avatar_seed
     END AS peer_avatar_seed,
     r.initiated_by = (SELECT auth.uid()) AS initiated_by_me,
     r.room_kind = 'group' AS is_group,
     r.title AS group_title,
     r.group_avatar_path,
     r.invite_token AS group_invite_token,
     r.invite_enabled AS group_invite_enabled,
     r.allow_member_invites AS group_allow_member_invites,
     r.created_by = (SELECT auth.uid()) AS is_group_owner,
     CASE
       WHEN r.room_kind = 'group' THEN (
         SELECT count(*)::integer
           FROM public.chat_room_members gm
          WHERE gm.room_id = r.room_id AND gm.left_at IS NULL)
       ELSE 2
     END AS member_count,
     COALESCE(lm.unread_count, 0) AS unread_count,
     lm.last_message_preview,
     lm.last_message_at,
     COALESCE(lm.last_own_message_read, false) AS last_own_message_read,
     COALESCE(lm.last_message_at, r.updated_at, r.created_at) AS sort_activity_at,
     CASE
       WHEN r.room_kind = 'group' THEN NULL::text
       WHEN r.initiated_by = (SELECT auth.uid())
         THEN NULLIF(btrim(peer_recv.profile_photo_url), '')
       ELSE NULLIF(btrim(peer_init.profile_photo_url), '')
     END AS peer_profile_photo_url,
     p.archived_at,
     p.cleared_at,
     CASE
       WHEN r.room_kind = 'group' THEN false
       WHEN r.initiated_by = (SELECT auth.uid())
         THEN COALESCE(peer_recv.is_verified, false)
       ELSE COALESCE(peer_init.is_verified, false)
     END AS peer_is_verified
    FROM public.chat_rooms r
    LEFT JOIN public.users peer_init ON peer_init.user_id = r.initiated_by
    LEFT JOIN public.users peer_recv ON peer_recv.user_id = r.received_by
    LEFT JOIN public.dm_room_prefs p
           ON p.room_id = r.room_id AND p.user_id = (SELECT auth.uid())
    LEFT JOIN LATERAL (
      SELECT
        (SELECT count(*)::integer
           FROM public.chat_messages m
          WHERE m.room_id = r.room_id
            AND m.sender_id IS DISTINCT FROM (SELECT auth.uid())
            AND m.deleted_at IS NULL
            AND (p.cleared_at IS NULL OR m.created_at > p.cleared_at)
            AND NOT EXISTS (
              SELECT 1 FROM public.chat_message_receipts rr
               WHERE rr.message_id = m.message_id
                 AND rr.user_id = (SELECT auth.uid())
                 AND rr.read_at IS NOT NULL)) AS unread_count,
        last_msg.preview   AS last_message_preview,
        last_msg.created_at AS last_message_at,
        (SELECT EXISTS (
            SELECT 1 FROM public.chat_message_receipts rr
             WHERE rr.message_id = own.message_id
               AND rr.read_at IS NOT NULL
               AND private.read_receipts_visible(rr.user_id))) AS last_own_message_read
      FROM (SELECT 1) AS anchor
      -- One row, read once. The preview and the time cannot come from
      -- different messages because there is only one message.
      LEFT JOIN LATERAL (
        SELECT COALESCE(
                 NULLIF(left(m.encrypted_payload, 280), ''),
                 CASE m.attached_media_type
                   WHEN 'audio' THEN 'Voice note'
                   WHEN 'image' THEN 'Photo'
                   WHEN 'video' THEN 'Video'
                   ELSE NULL
                 END) AS preview,
               m.created_at
          FROM public.chat_messages m
         WHERE m.room_id = r.room_id
           AND m.deleted_at IS NULL
           AND (p.cleared_at IS NULL OR m.created_at > p.cleared_at)
         -- The tie-break. Two messages written in one transaction share a
         -- created_at, and without this the newest of them is whichever the
         -- plan returns first.
         ORDER BY m.created_at DESC, m.message_id DESC
         LIMIT 1
      ) AS last_msg ON true
      LEFT JOIN LATERAL (
        SELECT m.message_id
          FROM public.chat_messages m
         WHERE m.room_id = r.room_id
           AND m.sender_id = (SELECT auth.uid())
           AND m.deleted_at IS NULL
           AND (p.cleared_at IS NULL OR m.created_at > p.cleared_at)
         ORDER BY m.created_at DESC, m.message_id DESC
         LIMIT 1
      ) AS own ON true
    ) lm ON true
   WHERE p.cleared_at IS NULL OR lm.last_message_at IS NOT NULL;

-- And the collision itself.
--
-- CURRENT_TIMESTAMP is the transaction's start time, identical for every row
-- written in one transaction. clock_timestamp() is the wall clock at the
-- moment of the insert, so two messages in one transaction are a few
-- microseconds apart and the later one really is later. For a message, "when
-- it was sent" is the more truthful of the two readings anyway.
--
-- A default change is catalog-only: no rewrite, no lock beyond the DDL itself,
-- and existing rows keep the values they have.
ALTER TABLE public.chat_messages
  ALTER COLUMN created_at SET DEFAULT pg_catalog.clock_timestamp();

SELECT public.record_migration(
  '20261056090000', 'the_last_message_is_one_message'
);

NOTIFY pgrst, 'reload schema';
