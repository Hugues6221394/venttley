-- Deleting an account should be hard to do by accident, impossible to do to
-- somebody else's community, and should actually take your content with it.
--
-- Three faults, reported together:
--
--   * the client asked "Delete account?" and deleted on Yes. No credential,
--     no second factor, nothing. A borrowed phone was enough.
--   * a keeper could delete themselves out from under a live tribe, leaving
--     the members with a community nobody owns.
--   * a deleted account's vents, stories and the notifications about it stayed
--     visible to everyone else. The account was gone; its footprint was not.
--
-- The 30-day grace period from 0075 is unchanged and is the reason the third
-- fault is fixed by *hiding* rather than deleting: content disappears the
-- moment you ask, and purge_due_accounts erases it when the window closes. If
-- you sign back in inside the window, everything comes back — which it cannot
-- do if it was already shredded.

-- ---------------------------------------------------------------------------
-- 1. Content follows the account out of sight
-- ---------------------------------------------------------------------------

-- One predicate already guards every readable post: it is the third clause of
-- the "posts readable" policy, so the feed, profiles, search, tribe content and
-- stories all pass through it. Deactivation belongs here rather than in each
-- of those read paths, where it would have to be remembered five times.
--
-- The author still sees their own, which matters for the grace period: a
-- restored account finds its posts where it left them. Staff keep their
-- separate "posts staff full read" policy, because a report filed against
-- somebody who then deletes their account must remain reviewable.
CREATE OR REPLACE FUNCTION private.can_view_post_author(p_author_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    p_author_id IS NULL
    OR p_author_id = (SELECT auth.uid())
    OR COALESCE(
      (
        SELECT u.shadow_banned IS NOT TRUE
               AND u.deactivated_at IS NULL
          FROM public.users u
         WHERE u.user_id = p_author_id
      ),
      TRUE
    );
$$;

-- Notifications about somebody who has left.
--
-- The old policy was FOR ALL with `user_id = auth.uid()`, which is right for
-- writing and too generous for reading: "X hugged your vent" outlives X. Split
-- so the read side can be stricter without loosening the write side, and so
-- that adding a condition here can never accidentally widen INSERT.
DROP POLICY IF EXISTS "notifications owner" ON public.notifications;

CREATE POLICY "notifications owner reads live actors"
  ON public.notifications FOR SELECT TO authenticated
  USING (
    user_id = (SELECT auth.uid())
    AND (
      actor_id IS NULL
      OR actor_id = (SELECT auth.uid())
      OR EXISTS (
        SELECT 1 FROM public.users u
         WHERE u.user_id = notifications.actor_id
           AND u.deactivated_at IS NULL
      )
    )
  );

CREATE POLICY "notifications owner writes"
  ON public.notifications FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "notifications owner updates"
  ON public.notifications FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "notifications owner deletes"
  ON public.notifications FOR DELETE TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- ---------------------------------------------------------------------------
-- 2. Deleting requires your password, and an orphan-free tribe
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.request_account_deletion(p_password TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me       UUID := (SELECT auth.uid());
  v_hash     TEXT;
  v_stranded TEXT;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not_signed_in' USING ERRCODE = '42501';
  END IF;

  -- Rate limited before the password is checked, so this cannot be used to
  -- test passwords. Five attempts an hour is far more than a person deleting
  -- their own account needs.
  IF NOT public.claim_rate_limit('account_deletion', 3600, 5) THEN
    RAISE EXCEPTION 'rate_limited' USING ERRCODE = '42901';
  END IF;

  SELECT encrypted_password INTO v_hash FROM auth.users WHERE id = v_me;

  -- An account with no password at all is one signed in by a provider, and
  -- there is nothing here to check against. Anything else must match.
  IF v_hash IS NOT NULL AND v_hash <> '' THEN
    IF p_password IS NULL OR p_password = '' THEN
      RAISE EXCEPTION 'password_required' USING ERRCODE = '42501';
    END IF;
    IF v_hash <> extensions.crypt(p_password, v_hash) THEN
      RAISE EXCEPTION 'password_incorrect' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- A keeper cannot leave a community without an owner. Empty tribes are
  -- fine — there is nobody to strand — and so is a tribe whose only remaining
  -- member is the keeper themselves.
  SELECT string_agg(t.name, ', ' ORDER BY t.name)
    INTO v_stranded
    FROM public.tribes t
   WHERE t.keeper_id = v_me
     AND EXISTS (
       SELECT 1 FROM public.tribe_members m
        WHERE m.tribe_id = t.tribe_id
          AND m.user_id <> v_me
     );

  IF v_stranded IS NOT NULL THEN
    RAISE EXCEPTION 'tribe_needs_a_keeper: %', v_stranded
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.users
     SET deactivated_at        = COALESCE(deactivated_at, now()),
         deletion_requested_at = now()
   WHERE user_id = v_me;
END $$;

REVOKE ALL ON FUNCTION public.request_account_deletion(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_account_deletion(TEXT) TO authenticated;

-- The old no-argument form is dropped rather than left beside the new one: a
-- client that still calls it would delete an account with no password at all,
-- which is the fault being fixed.
DROP FUNCTION IF EXISTS public.request_account_deletion();

SELECT public.record_migration(
  '20261038090000', 'account_deletion_is_deliberate'
);

NOTIFY pgrst, 'reload schema';
