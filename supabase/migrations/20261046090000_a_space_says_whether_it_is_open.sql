-- A Space that tells you it is closed, instead of letting you write a vent
-- and then refusing it.
--
-- The keeper's editor can set a Space read-only, restrict it to mods or to the
-- keeper, and schedule it to open on Monday and close on Friday. All four are
-- enforced, by the guard trigger on posts. None of them were visible: the
-- Space screen rendered "Start a Vent" unconditionally, so the first time
-- anybody learned a Space was shut was a raw 'space_is_read_only' or
-- 'space_posting_restricted' thrown at them after they had typed something.
--
-- Whether you can post is not a property of the Space alone — it depends on
-- your role in the tribe — so the client cannot work it out from the row it
-- already has. One function answers it, in the same order and with the same
-- conditions as the trigger, so what the screen shows and what the insert does
-- cannot disagree.

CREATE OR REPLACE FUNCTION public.my_space_posting_state(p_space_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me    UUID := (SELECT auth.uid());
  v_space public.spaces;
  v_role  TEXT;
BEGIN
  IF v_me IS NULL THEN RETURN 'signed_out'; END IF;

  SELECT * INTO v_space FROM public.spaces WHERE space_id = p_space_id;
  IF v_space.space_id IS NULL THEN RETURN 'not_found'; END IF;

  SELECT m.role INTO v_role
    FROM public.tribe_members AS m
   WHERE m.tribe_id = v_space.tribe_id AND m.user_id = v_me;

  -- Not a member at all. Said separately from the closed states because the
  -- answer is a different screen — join the tribe, not come back Monday.
  IF v_role IS NULL THEN RETURN 'not_a_member'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.tribe_members AS m
     WHERE m.tribe_id = v_space.tribe_id AND m.user_id = v_me
       AND m.muted_until > pg_catalog.now()
  ) THEN
    RETURN 'muted';
  END IF;

  -- Order matters, and matches the trigger: archived first, then the schedule,
  -- then the permission. A Space that is both archived and read-only should
  -- say archived, because that is the one that will not change on its own.
  IF v_space.archived_at IS NOT NULL THEN RETURN 'archived'; END IF;
  IF v_space.activates_at IS NOT NULL
     AND v_space.activates_at > pg_catalog.now() THEN
    RETURN 'not_open_yet';
  END IF;
  IF v_space.deactivates_at IS NOT NULL
     AND v_space.deactivates_at <= pg_catalog.now() THEN
    RETURN 'closed';
  END IF;

  IF v_space.posting_permission = 'read_only' THEN RETURN 'read_only'; END IF;
  IF v_space.posting_permission = 'mods'
     AND v_role NOT IN ('keeper', 'mod') THEN RETURN 'mods_only'; END IF;
  IF v_space.posting_permission = 'keeper'
     AND v_role <> 'keeper' THEN RETURN 'keeper_only'; END IF;

  RETURN 'open';
END;
$$;

REVOKE ALL ON FUNCTION public.my_space_posting_state(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_space_posting_state(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- The Spaces of a private tribe are not public.
-- ---------------------------------------------------------------------------
--
-- spaces_read_all was FOR SELECT USING (TRUE), so any signed-in account could
-- list the rooms inside any tribe. The names are the point: a tribe keeps
-- Spaces called things like "After the diagnosis", and the list of them
-- describes the tribe's members whether or not anybody can read a single vent
-- in them. Same shape as the membership roster, fixed in 20261045090000.
--
-- Public tribes stay open — being browsable is what public means.
--
-- But first: nobody could read them at all.
--
-- 0050 created the table, enabled RLS and wrote a FOR SELECT policy — but
-- never granted SELECT on it. The grant is checked before any policy, so the
-- policy has been decorating a table no client could open. Every Spaces list
-- in the app — the section on the tribe page, the keeper's Spaces tab, the
-- management screen — has been failing with
-- "permission denied for table spaces" since the feature shipped.
--
-- The view does not rescue it: space_directory is security_invoker, so reading
-- it checks the caller's privileges on the base table and fails the same way.
-- Which is why, on the local stack, there are three Spaces (all the automatic
-- "General") and not one post has ever been filed in one.
GRANT SELECT ON public.spaces TO authenticated;

DROP POLICY IF EXISTS "spaces_read_all" ON public.spaces;
DROP POLICY IF EXISTS "spaces readable" ON public.spaces;

CREATE POLICY "spaces readable"
  ON public.spaces FOR SELECT TO authenticated
  USING (
    -- Definer function rather than an inline EXISTS on tribes: "tribes
    -- readable" reads tribe_members, and evaluating it from here drags a
    -- second policy chain into every space query for no benefit. It also
    -- keeps this identical to the rule the roster uses.
    private.viewer_can_see_roster(tribe_id)
  );

-- ---------------------------------------------------------------------------
-- One way to change a Space, not two.
-- ---------------------------------------------------------------------------
--
-- 0050 shipped create_space, rename_space, archive_space and update_space_theme.
-- 20260716175655 then shipped manage_tribe_space, which does all of it, writes
-- an audit row for every change, and (since 20260901090000) authorises through
-- require_tribe_permission(..., 'manage_spaces') rather than keeper_id
-- equality.
--
-- The four originals were never updated and have no callers left in the app —
-- but they are still granted to authenticated, so they remain a live second
-- write path with the weaker auth model and no audit trail. A keeper who
-- delegated manage_spaces to a helper would find the helper's changes
-- unlogged, or a demoted keeper still able to rename rooms.
--
-- update_space_theme is also the only writer of spaces.theme_color, which the
-- client parses with int.parse and no validation. Removing it removes the only
-- way to get an unparseable value into that column.

DROP FUNCTION IF EXISTS public.create_space(UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.rename_space(UUID, TEXT);
DROP FUNCTION IF EXISTS public.archive_space(UUID);
DROP FUNCTION IF EXISTS public.update_space_theme(UUID, TEXT, TEXT, TEXT);

SELECT public.record_migration(
  '20261046090000', 'a_space_says_whether_it_is_open'
);

NOTIFY pgrst, 'reload schema';
