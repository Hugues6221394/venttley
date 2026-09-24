-- Deleting a conversation, archiving it, and locking it — each of them
-- yours alone.
--
-- Today the inbox has one long-press action, "Delete conversation", and it
-- runs `UPDATE chat_rooms SET room_status = 'declined'` straight from the
-- client. room_status is shared room state. The thread vanishes from the other
-- person's inbox too, they are never told, and nothing in the app can put it
-- back. There is no confirmation: a long press and one tap ends a conversation
-- for two people.
--
-- It is also the only way to get anything out of the inbox. Blocking does not
-- do it — guard_chat_message_block stops the messages and leaves the thread
-- sitting there. Leaving works, and is properly per-user, but only for groups.
--
-- So: three pieces of per-user state, on dm_room_prefs, which is already keyed
-- (room_id, user_id) with a self-only policy. The name is now a misnomer — it
-- holds state for group rooms as well, and has since set_dm_room_pref started
-- guarding on is_chat_room_member rather than on room_kind.
--
--   archived_at — out of the main list, into Archived. Reversible, keeps the
--                 messages, and stays archived when a new one arrives, which
--                 is the point of archiving rather than muting.
--
--   cleared_at  — "delete", honestly. You cannot take a message out of
--                 somebody else's phone, so this hides everything up to now
--                 from you and drops the room from your inbox until there is
--                 something new. The same shape chat_message_hides already
--                 uses for a single message.
--
--   locked_at   — the thread needs your face or your PIN to open. Stored here
--                 rather than on the device so the lock follows the account,
--                 and enforced on the device, because that is where the
--                 fingerprint reader is. It is not encryption and nothing here
--                 pretends otherwise: what it buys is that somebody holding
--                 your unlocked phone cannot read the thread. What the server
--                 does do is stop the preview text leaving the database at
--                 all, so a locked chat cannot leak through the inbox row or a
--                 push notification.

ALTER TABLE public.dm_room_prefs
  ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cleared_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS locked_at   TIMESTAMPTZ;

-- ---------------------------------------------------------------------------
-- The three verbs.
-- ---------------------------------------------------------------------------
--
-- Separate from set_dm_room_pref because that one COALESCEs every argument to
-- keep the old value, which cannot express "set this back to null". Archiving
-- and unarchiving are the same call with a boolean, and half of those calls
-- are a clear.

CREATE OR REPLACE FUNCTION public.set_chat_room_archived(
  p_room_id  UUID,
  p_archived BOOLEAN
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'not_a_participant';
  END IF;

  INSERT INTO public.dm_room_prefs (room_id, user_id, archived_at, updated_at)
  VALUES (
    p_room_id, (SELECT auth.uid()),
    CASE WHEN p_archived THEN pg_catalog.now() ELSE NULL END,
    pg_catalog.now()
  )
  ON CONFLICT (room_id, user_id) DO UPDATE SET
    archived_at = CASE WHEN p_archived THEN pg_catalog.now() ELSE NULL END,
    updated_at  = pg_catalog.now();
END;
$$;

CREATE OR REPLACE FUNCTION public.set_chat_room_locked(
  p_room_id UUID,
  p_locked  BOOLEAN
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'not_a_participant';
  END IF;

  INSERT INTO public.dm_room_prefs (room_id, user_id, locked_at, updated_at)
  VALUES (
    p_room_id, (SELECT auth.uid()),
    CASE WHEN p_locked THEN pg_catalog.now() ELSE NULL END,
    pg_catalog.now()
  )
  ON CONFLICT (room_id, user_id) DO UPDATE SET
    locked_at  = CASE WHEN p_locked THEN pg_catalog.now() ELSE NULL END,
    updated_at = pg_catalog.now();
END;
$$;

-- "Delete", for one person.
--
-- Named clear rather than delete because that is what it does, and because
-- delete_chat_room would be a promise the two-party case cannot keep.
CREATE OR REPLACE FUNCTION public.clear_chat_room(p_room_id UUID)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'not_a_participant';
  END IF;

  INSERT INTO public.dm_room_prefs (room_id, user_id, cleared_at, archived_at, updated_at)
  VALUES (p_room_id, (SELECT auth.uid()), pg_catalog.now(), NULL, pg_catalog.now())
  ON CONFLICT (room_id, user_id) DO UPDATE SET
    cleared_at = pg_catalog.now(),
    -- Clearing takes it out of the inbox entirely, so leaving it flagged as
    -- archived would file it under Archived the moment somebody writes again.
    archived_at = NULL,
    updated_at  = pg_catalog.now();
END;
$$;

REVOKE ALL ON FUNCTION public.set_chat_room_archived(UUID, BOOLEAN) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_chat_room_locked(UUID, BOOLEAN)  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.clear_chat_room(UUID)                FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_chat_room_archived(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_chat_room_locked(UUID, BOOLEAN)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_chat_room(UUID)                 TO authenticated;

-- ---------------------------------------------------------------------------
-- The inbox reads them.
-- ---------------------------------------------------------------------------
--
-- Written out in full rather than patched, because every one of the four
-- lateral subqueries needs the same new condition and the join has to be
-- ordered so the lateral can see it.

CREATE OR REPLACE VIEW public.inbox_rooms WITH (security_invoker = true) AS
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
            WHEN r.room_kind = 'group'::text THEN NULL::character varying
            WHEN r.initiated_by = auth.uid() THEN peer_recv.anonymous_pseudonym
            ELSE peer_init.anonymous_pseudonym
        END AS peer_pseudonym,
        CASE
            WHEN r.room_kind = 'group'::text THEN NULL::character varying
            WHEN r.initiated_by = auth.uid() THEN peer_recv.avatar_seed
            ELSE peer_init.avatar_seed
        END AS peer_avatar_seed,
    r.initiated_by = auth.uid() AS initiated_by_me,
    r.room_kind = 'group'::text AS is_group,
    r.title AS group_title,
    r.group_avatar_path,
    r.invite_token AS group_invite_token,
    r.invite_enabled AS group_invite_enabled,
    r.allow_member_invites AS group_allow_member_invites,
    r.created_by = auth.uid() AS is_group_owner,
        CASE
            WHEN r.room_kind = 'group'::text THEN ( SELECT count(*)::integer AS count
               FROM chat_room_members gm
              WHERE gm.room_id = r.room_id AND gm.left_at IS NULL)
            ELSE 2
        END AS member_count,
    COALESCE(lm.unread_count, 0) AS unread_count,
    -- A locked thread's last line does not leave the database. The inbox row
    -- renders it, and so does the foreground notification built from the same
    -- stream, so blanking it in the client would still have shipped it to the
    -- device.
    CASE WHEN p.locked_at IS NOT NULL THEN NULL::text
         ELSE lm.last_message_preview END AS last_message_preview,
    lm.last_message_at,
    COALESCE(lm.last_own_message_read, false) AS last_own_message_read,
    COALESCE(lm.last_message_at, r.updated_at, r.created_at) AS sort_activity_at,
        CASE
            WHEN r.room_kind = 'group'::text THEN NULL::text
            WHEN r.initiated_by = auth.uid() THEN NULLIF(btrim(peer_recv.profile_photo_url), ''::text)
            ELSE NULLIF(btrim(peer_init.profile_photo_url), ''::text)
        END AS peer_profile_photo_url,
    p.archived_at,
    p.locked_at,
    p.cleared_at
   FROM chat_rooms r
     LEFT JOIN users peer_init ON peer_init.user_id = r.initiated_by
     LEFT JOIN users peer_recv ON peer_recv.user_id = r.received_by
     LEFT JOIN dm_room_prefs p ON p.room_id = r.room_id AND p.user_id = auth.uid()
     LEFT JOIN LATERAL ( SELECT ( SELECT count(*)::integer AS count
                   FROM chat_messages m
                  WHERE m.room_id = r.room_id AND m.sender_id IS DISTINCT FROM auth.uid() AND m.deleted_at IS NULL
                    AND (p.cleared_at IS NULL OR m.created_at > p.cleared_at)
                    AND NOT (EXISTS ( SELECT 1
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
                    AND (p.cleared_at IS NULL OR m.created_at > p.cleared_at)
                  ORDER BY m.created_at DESC
                 LIMIT 1) AS last_message_preview,
            ( SELECT m.created_at
                   FROM chat_messages m
                  WHERE m.room_id = r.room_id AND m.deleted_at IS NULL
                    AND (p.cleared_at IS NULL OR m.created_at > p.cleared_at)
                  ORDER BY m.created_at DESC
                 LIMIT 1) AS last_message_at,
            ( SELECT (EXISTS ( SELECT 1
                           FROM chat_message_receipts rr
                          WHERE rr.message_id = m.message_id AND rr.read_at IS NOT NULL AND private.read_receipts_visible(rr.user_id))) AS "exists"
                   FROM chat_messages m
                  WHERE m.room_id = r.room_id AND m.sender_id = auth.uid() AND m.deleted_at IS NULL
                    AND (p.cleared_at IS NULL OR m.created_at > p.cleared_at)
                  ORDER BY m.created_at DESC
                 LIMIT 1) AS last_own_message_read) lm ON true
  -- A cleared room comes back the moment somebody writes again, which is the
  -- behaviour anybody who has used a messenger expects. Until then it is gone.
  -- Pending requests have no messages at all, so the test is on cleared_at
  -- rather than on emptiness.
  WHERE p.cleared_at IS NULL OR lm.last_message_at IS NOT NULL;

GRANT SELECT ON public.inbox_rooms TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.inbox_rooms FROM authenticated, anon;

-- ---------------------------------------------------------------------------
-- And the messages themselves, for the person who cleared them.
-- ---------------------------------------------------------------------------
--
-- The inbox hiding a room is not enough: opening it again after a new message
-- arrives would show the whole history back. chat_messages is read directly by
-- the client, so the cut has to be a policy.

DROP POLICY IF EXISTS "chat messages cleared are not mine" ON public.chat_messages;
CREATE POLICY "chat messages cleared are not mine"
  ON public.chat_messages AS RESTRICTIVE FOR SELECT TO authenticated
  USING (
    NOT EXISTS (
      SELECT 1 FROM public.dm_room_prefs AS p
       WHERE p.room_id = chat_messages.room_id
         AND p.user_id = (SELECT auth.uid())
         AND p.cleared_at IS NOT NULL
         AND chat_messages.created_at <= p.cleared_at
    )
  );

SELECT public.record_migration(
  '20261047090000', 'your_inbox_is_yours'
);

NOTIFY pgrst, 'reload schema';
