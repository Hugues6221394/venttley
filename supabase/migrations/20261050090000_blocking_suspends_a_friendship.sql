-- Unblocking somebody gives you your friend back.
--
-- It could not, because block_user did this:
--
--   DELETE FROM friendships
--    WHERE user_a = v_pair.user_a AND user_b = v_pair.user_b;
--
-- The friendship row was destroyed, so unblock_user — which only removes the
-- block — had nothing left to restore. Both people lost the connection
-- permanently, neither was told, and the only way back was to send a fresh
-- request and have it accepted.
--
-- So blocking suspends a friendship instead of ending it. The row stays; the
-- block hides it. That makes restoring free, and symmetric for free too:
-- has_block() looks in both directions, so one person blocking removes the
-- other from both friend lists, and removing the block puts them back in both.
--
-- The cost is that every query built on friendships now has to honour the
-- block, because the row it used to rely on being gone is still there.
-- online_friends and friend_suggestions already did. my_friends,
-- friend_stories_for_me and the two request views did not — and with the row
-- surviving, not filtering would mean a blocked person's stories appearing in
-- the feed, which is worse than the bug this fixes. All four are handled
-- below.
--
-- Friendships already destroyed by a past block are gone and cannot be
-- recovered; there is nothing left that records they existed.

-- ---------------------------------------------------------------------------
-- 0. has_block has to be able to see both directions.
-- ---------------------------------------------------------------------------
--
-- It reads like a symmetric test — blocker_id = a AND blocked_id = b, OR the
-- reverse — and it is not one, because it was SECURITY INVOKER and RLS on
-- user_blocks is `blocker_id = auth.uid()`. The person who was blocked cannot
-- see the row, so the function returned false for them.
--
-- That did not matter while blocking deleted the friendship: the row was gone
-- either way. It matters entirely now, because "unblocking restores it on both
-- sides" is exactly the half that was invisible.
--
-- SECURITY DEFINER, which is what friend_status already does when it reads the
-- same table to return 'blocked_me'. It discloses one boolean about a pair the
-- caller is half of, and the app already tells people they have been blocked.

CREATE OR REPLACE FUNCTION public.has_block(p_u1 UUID, p_u2 UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_blocks
     WHERE (blocker_id = p_u1 AND blocked_id = p_u2)
        OR (blocker_id = p_u2 AND blocked_id = p_u1)
  );
$$;

REVOKE ALL ON FUNCTION public.has_block(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_block(UUID, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 1. Blocking stops deleting.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.block_user(
  p_target UUID,
  p_reason TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF p_target = v_me THEN RAISE EXCEPTION 'cannot block yourself'; END IF;

  INSERT INTO public.user_blocks (blocker_id, blocked_id, reason)
  VALUES (v_me, p_target, p_reason)
  ON CONFLICT (blocker_id, blocked_id) DO UPDATE SET reason = EXCLUDED.reason;

  -- The friendship is deliberately left alone. It is hidden by every query
  -- below for as long as the block exists, and comes back the moment it does
  -- not. A pending request is suspended the same way rather than withdrawn:
  -- unblocking should not silently accept or cancel something somebody asked
  -- for before.
END;
$$;

REVOKE ALL ON FUNCTION public.block_user(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.block_user(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. The friend list honours the block, in both directions.
-- ---------------------------------------------------------------------------
--
-- Also excludes deactivated accounts. Deleting an account hides its content
-- everywhere else, but the person stayed in their friends' lists — a name that
-- opens a profile that no longer exists.

CREATE OR REPLACE VIEW public.my_friends WITH (security_invoker = true) AS
SELECT f.friendship_id,
    CASE WHEN f.user_a = auth.uid() THEN f.user_b ELSE f.user_a END AS friend_user_id,
    u.anonymous_pseudonym AS friend_pseudonym,
    u.avatar_seed AS friend_avatar_seed,
    u.karma_points AS friend_karma,
    u.is_verified AS friend_is_verified,
    f.accepted_at,
    f.created_at,
    u.profile_photo_url AS friend_profile_photo_url
   FROM friendships f
     JOIN users u ON u.user_id =
        CASE WHEN f.user_a = auth.uid() THEN f.user_b ELSE f.user_a END
  WHERE f.status = 'accepted'::text
    AND (auth.uid() = f.user_a OR auth.uid() = f.user_b)
    AND u.deactivated_at IS NULL
    AND NOT public.has_block(auth.uid(), u.user_id);

GRANT SELECT ON public.my_friends TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.my_friends FROM authenticated, anon;

-- ---------------------------------------------------------------------------
-- 3. So do the two request lists.
-- ---------------------------------------------------------------------------
--
-- Patched from their own live definitions: both grew a display-name column
-- since they were written, and retyping them is how one gets dropped.
DO $$
DECLARE
  v_def  TEXT;
  v_name TEXT;
BEGIN
  FOREACH v_name IN ARRAY ARRAY['friend_requests_inbox', 'friend_requests_outbox'] LOOP
    SELECT pg_get_viewdef(('public.' || v_name)::regclass, true) INTO v_def;

    IF position('f.requested_by' IN v_def) = 0 THEN
      RAISE EXCEPTION '% is not shaped as expected; refusing to patch blind', v_name;
    END IF;

    -- The final semicolon is the only reliable anchor: the two views differ in
    -- which side of the pair they join and in the tail of their WHERE.
    v_def := pg_catalog.rtrim(pg_catalog.rtrim(v_def), ';')
             || ' AND NOT public.has_block(auth.uid(), u.user_id)';

    EXECUTE 'CREATE OR REPLACE VIEW public.' || v_name
            || ' WITH (security_invoker = true) AS ' || v_def;
    EXECUTE 'GRANT SELECT ON public.' || v_name || ' TO authenticated';
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. And the story ring.
-- ---------------------------------------------------------------------------
--
-- This one never filtered blocks, because it did not have to: the friendship
-- row was gone, so a blocked person had no route into it. With the row
-- surviving, leaving it alone would put a blocked person's stories back in
-- front of the person who blocked them.
DO $$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'friend_stories_for_me';

  IF v_def IS NULL OR position('f.status = ''accepted''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'friend_stories_for_me is not shaped as expected';
  END IF;

  -- Skip rather than raise: a migration that cannot be applied twice cannot be
  -- replayed onto a fresh database either, and the guard exists to stop a
  -- double filter, not to stop a rerun.
  IF position('has_block' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_def := replace(
    v_def,
    'WHERE f.status = ''accepted''',
    'WHERE f.status = ''accepted''
            AND NOT public.has_block((SELECT auth.uid()), fp.author_id)'
  );

  EXECUTE v_def || ';';
END;
$$;

SELECT public.record_migration(
  '20261050090000', 'blocking_suspends_a_friendship'
);

NOTIFY pgrst, 'reload schema';
