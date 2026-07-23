-- Promote named chat rooms from a two-person DM wrapper into real private
-- groups. Direct-message behavior remains unchanged; group authorization is
-- driven by active chat_room_members rows and every write is server-gated.

CREATE SCHEMA IF NOT EXISTS private;

ALTER TABLE public.chat_rooms
  ADD COLUMN IF NOT EXISTS group_avatar_path TEXT,
  ADD COLUMN IF NOT EXISTS invite_token UUID DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS invite_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS allow_member_invites BOOLEAN NOT NULL DEFAULT TRUE;

CREATE UNIQUE INDEX IF NOT EXISTS chat_rooms_invite_token_unique
  ON public.chat_rooms (invite_token)
  WHERE room_kind = 'group' AND invite_token IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.chat_room_members (
  room_id UUID NOT NULL REFERENCES public.chat_rooms(room_id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  member_role TEXT NOT NULL DEFAULT 'member'
    CHECK (member_role IN ('owner', 'admin', 'member')),
  nickname TEXT CHECK (
    nickname IS NULL OR char_length(btrim(nickname)) BETWEEN 1 AND 40
  ),
  invited_by UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  left_at TIMESTAMPTZ,
  PRIMARY KEY (room_id, user_id)
);

CREATE INDEX IF NOT EXISTS chat_room_members_user_active_idx
  ON public.chat_room_members (user_id, joined_at DESC)
  WHERE left_at IS NULL;
CREATE INDEX IF NOT EXISTS chat_room_members_room_active_idx
  ON public.chat_room_members (room_id, joined_at)
  WHERE left_at IS NULL;

INSERT INTO public.chat_room_members (
  room_id, user_id, member_role, invited_by, joined_at
)
SELECT r.room_id, r.initiated_by, 'owner', r.initiated_by, r.created_at
  FROM public.chat_rooms r
 WHERE r.room_kind = 'group'
   AND r.initiated_by IS NOT NULL
ON CONFLICT (room_id, user_id) DO UPDATE
  SET member_role = 'owner', left_at = NULL;

INSERT INTO public.chat_room_members (
  room_id, user_id, member_role, invited_by, joined_at
)
SELECT r.room_id, r.received_by, 'member', r.initiated_by, r.created_at
  FROM public.chat_rooms r
 WHERE r.room_kind = 'group'
   AND r.received_by IS NOT NULL
ON CONFLICT (room_id, user_id) DO UPDATE SET left_at = NULL;

CREATE OR REPLACE FUNCTION private.is_chat_room_member(p_room_id UUID)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.chat_rooms r
     WHERE r.room_id = p_room_id
       AND (
         (r.room_kind = 'direct'
          AND (SELECT auth.uid()) IN (r.initiated_by, r.received_by))
         OR
         (r.room_kind = 'group' AND EXISTS (
           SELECT 1
             FROM public.chat_room_members m
            WHERE m.room_id = r.room_id
              AND m.user_id = (SELECT auth.uid())
              AND m.left_at IS NULL
         ))
       )
  );
$$;

REVOKE ALL ON FUNCTION private.is_chat_room_member(UUID) FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_chat_room_member(UUID) TO authenticated;

ALTER TABLE public.chat_room_members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "chat members room participants read"
  ON public.chat_room_members;
CREATE POLICY "chat members room participants read"
  ON public.chat_room_members FOR SELECT
  TO authenticated
  USING (private.is_chat_room_member(room_id));

REVOKE ALL ON public.chat_room_members FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.chat_room_members
  FROM authenticated;
GRANT SELECT ON public.chat_room_members TO authenticated;

-- Existing chat policies now understand active group members.
DROP POLICY IF EXISTS "chat_rooms participants read" ON public.chat_rooms;
CREATE POLICY "chat_rooms participants read"
  ON public.chat_rooms FOR SELECT
  TO authenticated
  USING (private.is_chat_room_member(room_id));

DROP POLICY IF EXISTS "chat_rooms participants update" ON public.chat_rooms;
CREATE POLICY "chat_rooms participants update"
  ON public.chat_rooms FOR UPDATE
  TO authenticated
  USING (private.is_chat_room_member(room_id))
  WITH CHECK (
    private.is_chat_room_member(room_id)
    AND (room_kind = 'direct' OR created_by = (SELECT auth.uid()))
  );

DROP POLICY IF EXISTS "chat_messages participants read" ON public.chat_messages;
CREATE POLICY "chat_messages participants read"
  ON public.chat_messages FOR SELECT
  TO authenticated
  USING (private.is_chat_room_member(room_id));

DROP POLICY IF EXISTS "chat_messages sender insert" ON public.chat_messages;
CREATE POLICY "chat_messages sender insert"
  ON public.chat_messages FOR INSERT
  TO authenticated
  WITH CHECK (
    sender_id = (SELECT auth.uid())
    AND private.is_chat_room_member(room_id)
    AND EXISTS (
      SELECT 1 FROM public.chat_rooms r
       WHERE r.room_id = chat_messages.room_id
         AND r.room_status = 'active'
    )
  );

DROP POLICY IF EXISTS "chat_reactions participant read"
  ON public.chat_message_reactions;
CREATE POLICY "chat_reactions participant read"
  ON public.chat_message_reactions FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.chat_messages m
       WHERE m.message_id = chat_message_reactions.message_id
         AND private.is_chat_room_member(m.room_id)
    )
  );

-- Private media stays private to active room members. Group avatars use the
-- same room-prefixed bucket and can therefore be signed by the mobile client.
DROP POLICY IF EXISTS "chat-media room participants read" ON storage.objects;
CREATE POLICY "chat-media room participants read"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'chat-media'
    AND EXISTS (
      SELECT 1 FROM public.chat_rooms r
       WHERE r.room_id::TEXT = split_part(name, '/', 1)
         AND private.is_chat_room_member(r.room_id)
    )
  );

DROP POLICY IF EXISTS "chat-media room participants insert" ON storage.objects;
CREATE POLICY "chat-media room participants insert"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'chat-media'
    AND owner = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.chat_rooms r
       WHERE r.room_id::TEXT = split_part(name, '/', 1)
         AND private.is_chat_room_member(r.room_id)
    )
  );

DROP POLICY IF EXISTS "chat-media object owner update" ON storage.objects;
CREATE POLICY "chat-media object owner update"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'chat-media'
    AND owner = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.chat_rooms r
       WHERE r.room_id::TEXT = split_part(name, '/', 1)
         AND private.is_chat_room_member(r.room_id)
    )
  )
  WITH CHECK (
    bucket_id = 'chat-media'
    AND owner = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.chat_rooms r
       WHERE r.room_id::TEXT = split_part(name, '/', 1)
         AND private.is_chat_room_member(r.room_id)
    )
  );

DROP POLICY IF EXISTS "chat-media object owner delete" ON storage.objects;
CREATE POLICY "chat-media object owner delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'chat-media'
    AND owner = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.chat_rooms r
       WHERE r.room_id::TEXT = split_part(name, '/', 1)
         AND private.is_chat_room_member(r.room_id)
    )
  );

-- Create a real group atomically with one or more accepted friends.
CREATE OR REPLACE FUNCTION public.create_group_chat_v2(
  p_title TEXT,
  p_member_ids UUID[]
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_room_id UUID;
  v_friend UUID;
  v_members UUID[];
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF char_length(btrim(COALESCE(p_title, ''))) NOT BETWEEN 2 AND 80 THEN
    RAISE EXCEPTION 'group_title_length';
  END IF;

  SELECT array_agg(DISTINCT x)
    INTO v_members
    FROM unnest(COALESCE(p_member_ids, ARRAY[]::UUID[])) x
   WHERE x IS NOT NULL AND x <> v_me;
  IF COALESCE(cardinality(v_members), 0) NOT BETWEEN 1 AND 49 THEN
    RAISE EXCEPTION 'group_member_count';
  END IF;

  FOREACH v_friend IN ARRAY v_members LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.friendships f
       WHERE f.status = 'accepted'
         AND v_me IN (f.user_a, f.user_b)
         AND v_friend IN (f.user_a, f.user_b)
    ) THEN
      RAISE EXCEPTION 'friends_only';
    END IF;
    IF public.has_block(v_me, v_friend) THEN RAISE EXCEPTION 'blocked'; END IF;
  END LOOP;

  INSERT INTO public.chat_rooms (
    initiated_by, received_by, request_preview, room_status, room_kind,
    title, created_by, invite_token, updated_at
  ) VALUES (
    v_me, v_members[1], 'Private group chat', 'active', 'group',
    btrim(p_title), v_me, gen_random_uuid(), now()
  ) RETURNING room_id INTO v_room_id;

  INSERT INTO public.chat_room_members (
    room_id, user_id, member_role, invited_by
  ) VALUES (v_room_id, v_me, 'owner', v_me);

  INSERT INTO public.chat_room_members (
    room_id, user_id, member_role, invited_by
  )
  SELECT v_room_id, x, 'member', v_me FROM unnest(v_members) x;

  RETURN v_room_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_group_chat(
  p_title TEXT,
  p_friend_id UUID
) RETURNS UUID
LANGUAGE SQL
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT public.create_group_chat_v2(p_title, ARRAY[p_friend_id]);
$$;

REVOKE ALL ON FUNCTION public.create_group_chat_v2(TEXT, UUID[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_group_chat_v2(TEXT, UUID[])
  TO authenticated;
REVOKE ALL ON FUNCTION public.create_group_chat(TEXT, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_group_chat(TEXT, UUID)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.group_chat_members(p_room_id UUID)
RETURNS TABLE (
  user_id UUID,
  pseudonym TEXT,
  avatar_seed TEXT,
  profile_photo_url TEXT,
  is_verified BOOLEAN,
  member_role TEXT,
  nickname TEXT,
  joined_at TIMESTAMPTZ,
  is_me BOOLEAN
)
LANGUAGE SQL
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT u.user_id,
         u.anonymous_pseudonym::TEXT,
         u.avatar_seed::TEXT,
         u.profile_photo_url,
         u.is_verified,
         m.member_role,
         m.nickname,
         m.joined_at,
         u.user_id = (SELECT auth.uid())
    FROM public.chat_room_members m
    JOIN public.users u ON u.user_id = m.user_id
   WHERE m.room_id = p_room_id
     AND m.left_at IS NULL
     AND private.is_chat_room_member(p_room_id)
   ORDER BY (m.member_role = 'owner') DESC,
            (m.member_role = 'admin') DESC,
            m.joined_at,
            u.anonymous_pseudonym;
$$;

REVOKE ALL ON FUNCTION public.group_chat_members(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.group_chat_members(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.add_group_chat_members(
  p_room_id UUID,
  p_member_ids UUID[]
) RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_target UUID;
  v_targets UUID[];
  v_room public.chat_rooms%ROWTYPE;
  v_count INT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT * INTO v_room FROM public.chat_rooms r WHERE r.room_id = p_room_id;
  IF NOT FOUND OR v_room.room_kind <> 'group' OR v_room.room_status <> 'active'
  THEN RAISE EXCEPTION 'group_not_found'; END IF;
  IF NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'not_a_group_member';
  END IF;
  IF v_room.created_by <> v_me AND NOT v_room.allow_member_invites THEN
    RAISE EXCEPTION 'member_invites_disabled';
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_targets
    FROM unnest(COALESCE(p_member_ids, ARRAY[]::UUID[])) x
   WHERE x IS NOT NULL
     AND x <> v_me
     AND NOT EXISTS (
       SELECT 1 FROM public.chat_room_members existing
        WHERE existing.room_id = p_room_id
          AND existing.user_id = x
          AND existing.left_at IS NULL
     );
  IF COALESCE(cardinality(v_targets), 0) = 0 THEN RETURN 0; END IF;
  IF (SELECT count(*) FROM public.chat_room_members m
       WHERE m.room_id = p_room_id AND m.left_at IS NULL)
       + cardinality(v_targets) > 50 THEN
    RAISE EXCEPTION 'group_member_limit';
  END IF;

  FOREACH v_target IN ARRAY v_targets LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.friendships f
       WHERE f.status = 'accepted'
         AND v_me IN (f.user_a, f.user_b)
         AND v_target IN (f.user_a, f.user_b)
    ) THEN RAISE EXCEPTION 'friends_only'; END IF;
    IF public.has_block(v_me, v_target) THEN RAISE EXCEPTION 'blocked'; END IF;
  END LOOP;

  INSERT INTO public.chat_room_members (
    room_id, user_id, member_role, invited_by, joined_at, left_at
  )
  SELECT p_room_id, x, 'member', v_me, now(), NULL
    FROM unnest(v_targets) x
  ON CONFLICT (room_id, user_id) DO UPDATE
    SET left_at = NULL,
        member_role = CASE
          WHEN chat_room_members.member_role = 'owner' THEN 'owner'
          ELSE 'member'
        END,
        invited_by = v_me,
        joined_at = now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  UPDATE public.chat_rooms SET updated_at = now() WHERE room_id = p_room_id;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.add_group_chat_members(UUID, UUID[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_group_chat_members(UUID, UUID[])
  TO authenticated;

CREATE OR REPLACE FUNCTION public.remove_group_chat_member(
  p_room_id UUID,
  p_user_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid()); v_owner UUID;
BEGIN
  SELECT r.created_by INTO v_owner
    FROM public.chat_rooms r
   WHERE r.room_id = p_room_id AND r.room_kind = 'group';
  IF v_owner IS NULL THEN RAISE EXCEPTION 'group_not_found'; END IF;
  IF v_owner <> v_me THEN RAISE EXCEPTION 'owner_only'; END IF;
  IF p_user_id = v_me THEN RAISE EXCEPTION 'owner_must_leave'; END IF;
  UPDATE public.chat_room_members
     SET left_at = now()
   WHERE room_id = p_room_id AND user_id = p_user_id AND left_at IS NULL;
  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.remove_group_chat_member(UUID, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remove_group_chat_member(UUID, UUID)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.leave_group_chat(p_room_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_owner UUID;
  v_next UUID;
BEGIN
  SELECT r.created_by INTO v_owner
    FROM public.chat_rooms r
   WHERE r.room_id = p_room_id AND r.room_kind = 'group';
  IF v_owner IS NULL OR NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'group_not_found';
  END IF;

  UPDATE public.chat_room_members
     SET left_at = now(), member_role = 'member'
   WHERE room_id = p_room_id AND user_id = v_me AND left_at IS NULL;
  IF NOT FOUND THEN RETURN FALSE; END IF;

  IF v_owner = v_me THEN
    SELECT m.user_id INTO v_next
      FROM public.chat_room_members m
     WHERE m.room_id = p_room_id AND m.left_at IS NULL
     ORDER BY (m.member_role = 'admin') DESC, m.joined_at
     LIMIT 1;
    IF v_next IS NULL THEN
      UPDATE public.chat_rooms
         SET room_status = 'declined', updated_at = now()
       WHERE room_id = p_room_id;
    ELSE
      UPDATE public.chat_room_members
         SET member_role = 'owner'
       WHERE room_id = p_room_id AND user_id = v_next;
      UPDATE public.chat_rooms
         SET created_by = v_next, updated_at = now()
       WHERE room_id = p_room_id;
    END IF;
  END IF;
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.leave_group_chat(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.leave_group_chat(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_group_spam_and_leave(p_room_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid());
BEGIN
  IF v_me IS NULL OR NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'group_not_found';
  END IF;
  INSERT INTO public.reports (target_room_id, reporter_id, reason, note)
  VALUES (p_room_id, v_me, 'spam', 'Marked as spam while leaving group')
  ON CONFLICT DO NOTHING;
  RETURN public.leave_group_chat(p_room_id);
END;
$$;

REVOKE ALL ON FUNCTION public.mark_group_spam_and_leave(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_group_spam_and_leave(UUID)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.update_group_chat_identity(
  p_room_id UUID,
  p_title TEXT DEFAULT NULL,
  p_avatar_path TEXT DEFAULT NULL,
  p_clear_avatar BOOLEAN DEFAULT FALSE
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid()); v_owner UUID;
BEGIN
  SELECT r.created_by INTO v_owner FROM public.chat_rooms r
   WHERE r.room_id = p_room_id AND r.room_kind = 'group';
  IF v_owner IS NULL THEN RAISE EXCEPTION 'group_not_found'; END IF;
  IF v_owner <> v_me THEN RAISE EXCEPTION 'owner_only'; END IF;
  IF p_title IS NOT NULL AND
     char_length(btrim(p_title)) NOT BETWEEN 2 AND 80 THEN
    RAISE EXCEPTION 'group_title_length';
  END IF;
  IF p_avatar_path IS NOT NULL AND
     p_avatar_path !~ ('^' || p_room_id::TEXT || '/group-avatar-') THEN
    RAISE EXCEPTION 'invalid_group_avatar_path';
  END IF;
  UPDATE public.chat_rooms
     SET title = COALESCE(btrim(p_title), title),
         group_avatar_path = CASE
           WHEN p_clear_avatar THEN NULL
           ELSE COALESCE(p_avatar_path, group_avatar_path)
         END,
         updated_at = now()
   WHERE room_id = p_room_id;
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.update_group_chat_identity(
  UUID, TEXT, TEXT, BOOLEAN
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_group_chat_identity(
  UUID, TEXT, TEXT, BOOLEAN
) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_group_chat_nickname(
  p_room_id UUID,
  p_nickname TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid());
BEGIN
  IF NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'not_a_group_member';
  END IF;
  IF p_nickname IS NOT NULL AND btrim(p_nickname) <> '' AND
     char_length(btrim(p_nickname)) > 40 THEN
    RAISE EXCEPTION 'nickname_too_long';
  END IF;
  UPDATE public.chat_room_members
     SET nickname = NULLIF(btrim(p_nickname), '')
   WHERE room_id = p_room_id AND user_id = v_me AND left_at IS NULL;
  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.set_group_chat_nickname(UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_group_chat_nickname(UUID, TEXT)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.set_group_chat_privacy(
  p_room_id UUID,
  p_allow_member_invites BOOLEAN DEFAULT NULL,
  p_invite_enabled BOOLEAN DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid()); v_owner UUID;
BEGIN
  SELECT r.created_by INTO v_owner FROM public.chat_rooms r
   WHERE r.room_id = p_room_id AND r.room_kind = 'group';
  IF v_owner IS NULL THEN RAISE EXCEPTION 'group_not_found'; END IF;
  IF v_owner <> v_me THEN RAISE EXCEPTION 'owner_only'; END IF;
  UPDATE public.chat_rooms
     SET allow_member_invites = COALESCE(
           p_allow_member_invites, allow_member_invites
         ),
         invite_enabled = COALESCE(p_invite_enabled, invite_enabled),
         updated_at = now()
   WHERE room_id = p_room_id;
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.set_group_chat_privacy(
  UUID, BOOLEAN, BOOLEAN
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_group_chat_privacy(
  UUID, BOOLEAN, BOOLEAN
) TO authenticated;

CREATE OR REPLACE FUNCTION public.regenerate_group_invite(p_room_id UUID)
RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid()); v_token UUID;
BEGIN
  UPDATE public.chat_rooms
     SET invite_token = gen_random_uuid(), invite_enabled = TRUE,
         updated_at = now()
   WHERE room_id = p_room_id
     AND room_kind = 'group'
     AND created_by = v_me
  RETURNING invite_token INTO v_token;
  IF v_token IS NULL THEN RAISE EXCEPTION 'owner_only'; END IF;
  RETURN v_token;
END;
$$;

REVOKE ALL ON FUNCTION public.regenerate_group_invite(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.regenerate_group_invite(UUID)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.group_invite_preview(p_token UUID)
RETURNS TABLE (
  room_id UUID,
  title TEXT,
  group_avatar_path TEXT,
  member_count INT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  RETURN QUERY
  SELECT r.room_id, r.title, r.group_avatar_path,
         (SELECT count(*)::INT FROM public.chat_room_members m
           WHERE m.room_id = r.room_id AND m.left_at IS NULL)
    FROM public.chat_rooms r
   WHERE r.invite_token = p_token
     AND r.room_kind = 'group'
     AND r.room_status = 'active'
     AND r.invite_enabled;
END;
$$;

CREATE OR REPLACE FUNCTION public.join_group_chat_by_invite(p_token UUID)
RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid()); v_room public.chat_rooms%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT * INTO v_room FROM public.chat_rooms r
   WHERE r.invite_token = p_token
     AND r.room_kind = 'group'
     AND r.room_status = 'active'
     AND r.invite_enabled;
  IF NOT FOUND THEN RAISE EXCEPTION 'invite_not_found'; END IF;
  IF v_room.created_by IS NOT NULL AND public.has_block(v_me, v_room.created_by)
  THEN RAISE EXCEPTION 'blocked'; END IF;
  IF (SELECT count(*) FROM public.chat_room_members m
       WHERE m.room_id = v_room.room_id AND m.left_at IS NULL) >= 50 THEN
    RAISE EXCEPTION 'group_member_limit';
  END IF;
  INSERT INTO public.chat_room_members (
    room_id, user_id, member_role, invited_by, joined_at, left_at
  ) VALUES (
    v_room.room_id, v_me, 'member', v_room.created_by, now(), NULL
  )
  ON CONFLICT (room_id, user_id) DO UPDATE
    SET left_at = NULL, joined_at = now();
  RETURN v_room.room_id;
END;
$$;

REVOKE ALL ON FUNCTION public.group_invite_preview(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.group_invite_preview(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.join_group_chat_by_invite(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.join_group_chat_by_invite(UUID)
  TO authenticated;

-- Per-user font selection completes the existing theme customization.
ALTER TABLE public.dm_room_prefs
  ADD COLUMN IF NOT EXISTS font_style TEXT NOT NULL DEFAULT 'default'
  CHECK (font_style IN ('default', 'serif', 'mono'));

DROP FUNCTION IF EXISTS public.set_dm_room_pref(
  UUID, BOOLEAN, TEXT, BOOLEAN, INT, TEXT
);
CREATE FUNCTION public.set_dm_room_pref(
  p_room_id UUID,
  p_muted BOOLEAN DEFAULT NULL,
  p_peer_nickname TEXT DEFAULT NULL,
  p_clear_nickname BOOLEAN DEFAULT FALSE,
  p_disappearing INT DEFAULT NULL,
  p_theme TEXT DEFAULT NULL,
  p_font_style TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid());
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'not_a_room_participant';
  END IF;
  IF p_font_style IS NOT NULL AND
     p_font_style NOT IN ('default', 'serif', 'mono') THEN
    RAISE EXCEPTION 'invalid_font_style';
  END IF;
  INSERT INTO public.dm_room_prefs (room_id, user_id)
  VALUES (p_room_id, v_me)
  ON CONFLICT (room_id, user_id) DO NOTHING;
  UPDATE public.dm_room_prefs
     SET muted = COALESCE(p_muted, muted),
         peer_nickname = CASE WHEN p_clear_nickname THEN NULL
           ELSE COALESCE(p_peer_nickname, peer_nickname) END,
         disappearing_seconds = COALESCE(p_disappearing, disappearing_seconds),
         theme = COALESCE(p_theme, theme),
         font_style = COALESCE(p_font_style, font_style),
         updated_at = now()
   WHERE room_id = p_room_id AND user_id = v_me;
END;
$$;

REVOKE ALL ON FUNCTION public.set_dm_room_pref(
  UUID, BOOLEAN, TEXT, BOOLEAN, INT, TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_dm_room_pref(
  UUID, BOOLEAN, TEXT, BOOLEAN, INT, TEXT, TEXT
) TO authenticated;

-- Membership-aware canonical send. The rest of the media, post-snapshot and
-- idempotency contracts are preserved exactly.
CREATE OR REPLACE FUNCTION public.send_chat_message(
  p_room_id UUID,
  p_payload TEXT,
  p_attached_post_id UUID DEFAULT NULL,
  p_media_path TEXT DEFAULT NULL,
  p_media_type TEXT DEFAULT NULL
) RETURNS TABLE (
  message_id UUID,
  room_id UUID,
  sender_id UUID,
  payload TEXT,
  attached_post_id UUID,
  attached_post_snapshot JSONB,
  attached_media_path TEXT,
  attached_media_type TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_room public.chat_rooms%ROWTYPE;
  v_snapshot JSONB;
  v_row public.chat_messages%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT * INTO v_room FROM public.chat_rooms r WHERE r.room_id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'room not found'; END IF;
  IF NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'not a participant';
  END IF;
  IF v_room.room_status <> 'active' THEN RAISE EXCEPTION 'room is not active'; END IF;
  IF (p_media_path IS NULL) <> (p_media_type IS NULL) THEN
    RAISE EXCEPTION 'media path and type must be provided together';
  END IF;
  IF p_media_path IS NOT NULL AND
     p_media_path !~ ('^' || p_room_id::TEXT || '/') THEN
    RAISE EXCEPTION 'media path must be in room prefix';
  END IF;
  IF p_media_type IS NOT NULL AND p_media_type NOT IN ('image', 'audio') THEN
    RAISE EXCEPTION 'unsupported media type';
  END IF;
  IF btrim(COALESCE(p_payload, '')) = ''
     AND p_attached_post_id IS NULL AND p_media_path IS NULL THEN
    RAISE EXCEPTION 'message must have content or an attachment';
  END IF;
  IF p_attached_post_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'post_id', p.post_id, 'content', left(p.content, 400),
      'author_id', p.author_id, 'category', p.category_name,
      'mood', p.post_mood, 'is_whisper', p.is_whisper,
      'created_at', p.created_at,
      'author_pseudonym', COALESCE(
        '@' || pr.pseudonym, '@' || u.anonymous_pseudonym
      ),
      'author_avatar_seed', COALESCE(pr.avatar_seed, u.avatar_seed)
    ) INTO v_snapshot
      FROM public.posts p
      LEFT JOIN public.users u ON u.user_id = p.author_id
      LEFT JOIN public.personas pr
        ON pr.persona_id = p.persona_id AND pr.deleted_at IS NULL
     WHERE p.post_id = p_attached_post_id
       AND p.deleted_at IS NULL
       AND (
         p.tribe_id IS NULL
         OR NOT EXISTS (
           SELECT 1 FROM public.tribes t
            WHERE t.tribe_id = p.tribe_id AND t.is_private
         )
         OR EXISTS (
           SELECT 1 FROM public.tribe_members tm
            WHERE tm.tribe_id = p.tribe_id AND tm.user_id = v_me
         )
       );
    IF v_snapshot IS NULL THEN
      RAISE EXCEPTION 'attached post not found or not readable';
    END IF;
  END IF;
  INSERT INTO public.chat_messages (
    room_id, sender_id, encrypted_payload, nonce_iv, attached_post_id,
    attached_post_snapshot, attached_media_path, attached_media_type
  ) VALUES (
    p_room_id, v_me, COALESCE(p_payload, ''), 'v1-plaintext',
    p_attached_post_id, v_snapshot, p_media_path, p_media_type
  ) RETURNING * INTO v_row;
  message_id := v_row.message_id;
  room_id := v_row.room_id;
  sender_id := v_row.sender_id;
  payload := v_row.encrypted_payload;
  attached_post_id := v_row.attached_post_id;
  attached_post_snapshot := v_row.attached_post_snapshot;
  attached_media_path := v_row.attached_media_path;
  attached_media_type := v_row.attached_media_type;
  created_at := v_row.created_at;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.send_chat_message(
  UUID, TEXT, UUID, TEXT, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_chat_message(
  UUID, TEXT, UUID, TEXT, TEXT
) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_chat_message_reaction(
  p_message_id UUID,
  p_reaction_type TEXT
) RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid()); v_room UUID; v_current TEXT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT m.room_id INTO v_room FROM public.chat_messages m
   WHERE m.message_id = p_message_id;
  IF v_room IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
  IF NOT private.is_chat_room_member(v_room) THEN
    RAISE EXCEPTION 'not a participant';
  END IF;
  SELECT r.reaction_type INTO v_current
    FROM public.chat_message_reactions r
   WHERE r.message_id = p_message_id AND r.user_id = v_me;
  IF p_reaction_type IS NULL OR v_current = p_reaction_type THEN
    DELETE FROM public.chat_message_reactions
     WHERE message_id = p_message_id AND user_id = v_me;
    RETURN NULL;
  END IF;
  INSERT INTO public.chat_message_reactions (
    message_id, user_id, reaction_type
  ) VALUES (p_message_id, v_me, p_reaction_type)
  ON CONFLICT (message_id, user_id) DO UPDATE
    SET reaction_type = EXCLUDED.reaction_type, created_at = now();
  RETURN p_reaction_type;
END;
$$;

REVOKE ALL ON FUNCTION public.set_chat_message_reaction(UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_chat_message_reaction(UUID, TEXT)
  TO authenticated;

-- Per-member receipts make unread counts honest after a third member joins.
CREATE TABLE IF NOT EXISTS public.chat_message_receipts (
  message_id UUID NOT NULL REFERENCES public.chat_messages(message_id)
    ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  delivered_at TIMESTAMPTZ,
  read_at TIMESTAMPTZ,
  PRIMARY KEY (message_id, user_id)
);
ALTER TABLE public.chat_message_receipts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "chat receipts room participants read"
  ON public.chat_message_receipts;
CREATE POLICY "chat receipts room participants read"
  ON public.chat_message_receipts FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.chat_messages m
       WHERE m.message_id = chat_message_receipts.message_id
         AND private.is_chat_room_member(m.room_id)
    )
  );
REVOKE ALL ON public.chat_message_receipts FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.chat_message_receipts
  FROM authenticated;
GRANT SELECT ON public.chat_message_receipts TO authenticated;

-- Preserve the historical direct-message receipt state so this migration
-- cannot make already-read conversations appear unread again.
INSERT INTO public.chat_message_receipts (
  message_id, user_id, delivered_at, read_at
)
SELECT m.message_id,
       CASE WHEN m.sender_id = r.initiated_by
            THEN r.received_by ELSE r.initiated_by END,
       m.delivered_at,
       m.read_at
  FROM public.chat_messages m
  JOIN public.chat_rooms r ON r.room_id = m.room_id
 WHERE r.room_kind = 'direct'
   AND m.sender_id IN (r.initiated_by, r.received_by)
   AND (m.delivered_at IS NOT NULL OR m.read_at IS NOT NULL)
ON CONFLICT (message_id, user_id) DO UPDATE
  SET delivered_at = COALESCE(
        chat_message_receipts.delivered_at, EXCLUDED.delivered_at
      ),
      read_at = COALESCE(chat_message_receipts.read_at, EXCLUDED.read_at);

INSERT INTO public.chat_message_receipts (
  message_id, user_id, delivered_at, read_at
)
SELECT m.message_id, gm.user_id, m.delivered_at, m.read_at
  FROM public.chat_messages m
  JOIN public.chat_rooms r ON r.room_id = m.room_id
  JOIN public.chat_room_members gm
    ON gm.room_id = r.room_id
   AND gm.left_at IS NULL
   AND gm.user_id <> m.sender_id
 WHERE r.room_kind = 'group'
   AND (m.delivered_at IS NOT NULL OR m.read_at IS NOT NULL)
ON CONFLICT (message_id, user_id) DO UPDATE
  SET delivered_at = COALESCE(
        chat_message_receipts.delivered_at, EXCLUDED.delivered_at
      ),
      read_at = COALESCE(chat_message_receipts.read_at, EXCLUDED.read_at);

CREATE OR REPLACE FUNCTION public.mark_chat_room_read(p_room_id UUID)
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid()); v_count INT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'not a participant';
  END IF;
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
  UPDATE public.chat_messages
     SET read_at = COALESCE(read_at, now()),
         delivered_at = COALESCE(delivered_at, now())
   WHERE room_id = p_room_id AND sender_id <> v_me;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_room_delivered(p_room_id UUID)
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid()); v_count INT;
BEGIN
  IF v_me IS NULL OR NOT private.is_chat_room_member(p_room_id) THEN RETURN 0; END IF;
  WITH inserted AS (
    INSERT INTO public.chat_message_receipts (
      message_id, user_id, delivered_at
    )
    SELECT m.message_id, v_me, now()
      FROM public.chat_messages m
     WHERE m.room_id = p_room_id AND m.sender_id <> v_me
    ON CONFLICT (message_id, user_id) DO UPDATE
      SET delivered_at = COALESCE(
        chat_message_receipts.delivered_at, EXCLUDED.delivered_at
      )
      WHERE chat_message_receipts.delivered_at IS NULL
    RETURNING message_id
  ) SELECT count(*)::INT INTO v_count FROM inserted;
  UPDATE public.chat_messages SET delivered_at = COALESCE(delivered_at, now())
   WHERE room_id = p_room_id AND sender_id <> v_me;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_chat_room_read(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_chat_room_read(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.mark_room_delivered(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_room_delivered(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.hide_chat_message(p_message_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid()); v_room UUID;
BEGIN
  SELECT m.room_id INTO v_room FROM public.chat_messages m
   WHERE m.message_id = p_message_id;
  IF v_me IS NULL OR v_room IS NULL OR NOT private.is_chat_room_member(v_room)
  THEN RAISE EXCEPTION 'message not found'; END IF;
  INSERT INTO public.chat_message_hides (message_id, user_id)
  VALUES (p_message_id, v_me) ON CONFLICT DO NOTHING;
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.hide_chat_message(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hide_chat_message(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.edit_chat_message(
  p_message_id UUID,
  p_plaintext TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_room UUID;
  v_created TIMESTAMPTZ;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF btrim(COALESCE(p_plaintext, '')) = '' THEN
    RAISE EXCEPTION 'empty edit not allowed';
  END IF;
  IF length(p_plaintext) > 4000 THEN RAISE EXCEPTION 'message too long'; END IF;
  SELECT m.room_id, m.created_at INTO v_room, v_created
    FROM public.chat_messages m
   WHERE m.message_id = p_message_id
     AND m.sender_id = v_me
     AND m.deleted_at IS NULL;
  IF v_room IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
  IF NOT private.is_chat_room_member(v_room) THEN
    RAISE EXCEPTION 'not a participant';
  END IF;
  IF now() - v_created > INTERVAL '30 minutes' THEN
    RAISE EXCEPTION 'edit window expired';
  END IF;
  UPDATE public.chat_messages
     SET encrypted_payload = p_plaintext, edited_at = now()
   WHERE message_id = p_message_id;
  RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_chat_message(p_message_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_room UUID;
  v_created TIMESTAMPTZ;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT m.room_id, m.created_at INTO v_room, v_created
    FROM public.chat_messages m
   WHERE m.message_id = p_message_id AND m.sender_id = v_me;
  IF v_room IS NULL THEN RAISE EXCEPTION 'message not found'; END IF;
  IF NOT private.is_chat_room_member(v_room) THEN
    RAISE EXCEPTION 'not a participant';
  END IF;
  IF now() - v_created > INTERVAL '24 hours' THEN
    RAISE EXCEPTION 'delete-for-everyone window expired';
  END IF;
  UPDATE public.chat_messages
     SET deleted_at = now(), encrypted_payload = ''
   WHERE message_id = p_message_id;
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.edit_chat_message(UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edit_chat_message(UUID, TEXT)
  TO authenticated;
REVOKE ALL ON FUNCTION public.delete_chat_message(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_chat_message(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_room_disappearing(
  p_room_id UUID,
  p_seconds INT
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF p_seconds < 0 THEN RAISE EXCEPTION 'invalid ttl'; END IF;
  IF NOT private.is_chat_room_member(p_room_id) THEN
    RAISE EXCEPTION 'not a room participant';
  END IF;
  UPDATE public.chat_rooms
     SET disappearing_seconds = p_seconds, updated_at = now()
   WHERE room_id = p_room_id;
END;
$$;

REVOKE ALL ON FUNCTION public.set_room_disappearing(UUID, INT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_room_disappearing(UUID, INT)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.unread_chat_message_count()
RETURNS INT
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT count(*)::INT
    FROM public.chat_messages m
    JOIN public.chat_rooms r ON r.room_id = m.room_id
   WHERE r.room_status = 'active'
     AND private.is_chat_room_member(r.room_id)
     AND m.sender_id IS DISTINCT FROM (SELECT auth.uid())
     AND m.deleted_at IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.chat_message_receipts rr
        WHERE rr.message_id = m.message_id
          AND rr.user_id = (SELECT auth.uid())
          AND rr.read_at IS NOT NULL
     );
$$;

REVOKE ALL ON FUNCTION public.unread_chat_message_count() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unread_chat_message_count() TO authenticated;

-- Rebuild the inbox with group membership filtering, real member counts and
-- the identity/privacy fields used by the settings UI.
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
  COALESCE(lm.last_message_at, r.updated_at, r.created_at) AS sort_activity_at
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

GRANT SELECT ON public.inbox_rooms TO authenticated;
REVOKE SELECT ON public.inbox_rooms FROM anon;

-- RLS is not evaluated for TRUNCATE. Remove the broad default grants that
-- would otherwise let API roles attempt destructive table-wide operations.
REVOKE TRUNCATE ON public.chat_rooms, public.chat_messages,
  public.chat_message_reactions, public.chat_message_hides,
  public.dm_room_prefs FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';
