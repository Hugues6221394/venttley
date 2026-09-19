-- Tie public.users to auth.users, and clear the rows that prove it was never tied.
--
-- public.users.user_id has always held an auth.users id, and nothing ever said
-- so. Deleting an account through the Supabase dashboard or the Auth Admin API
-- therefore removed the Auth identity and left the profile row behind, intact,
-- still carrying its role. Two such rows exist:
--
--   5033df7b…  staff_0d0234dc5277c55c  normal     suspended  15 Sep
--   8f99502e…  staff_5995acc9efc1e2a4  moderator  active     18 Sep
--
-- Both are staff invitations that were deleted after going wrong. Neither can
-- sign in -- there is no identity to sign in as -- so neither is directly
-- exploitable. But is_staff() returns true for the second one, it appears in
-- the staff list as an active moderator, and any future code that reaches a
-- user by profile id rather than through a session would treat it as staff.
-- A privileged row with nobody behind it is not a state this schema should be
-- able to reach.
--
-- ON DELETE CASCADE, not RESTRICT
--
-- 103 foreign keys already point at public.users: 60 CASCADE, 43 SET NULL,
-- none RESTRICT. The schema has always described what deleting a member means
-- -- their content goes, their traces are anonymised. What was missing is that
-- deleting the Auth account never started it. CASCADE makes the Auth delete
-- mean what the rest of the schema already says it means.
--
-- The two guards that matter survive it:
--
--   * prevent_legal_hold_user_delete is a BEFORE DELETE trigger on
--     public.users. Row triggers fire on cascaded deletes, so an account with
--     an open CSAM incident still aborts -- and now aborts the Auth delete
--     along with it, which is stronger than today, where the Auth account
--     could be removed while the evidence link stayed behind.
--   * public.audit_log has no foreign keys at all, by design. The trail is not
--     reachable from this cascade and outlives the account. Six existing rows
--     reference these two orphans as target_id; they stay exactly as written.
--
-- RESTRICT was the alternative: refuse the Auth delete while a profile exists,
-- forcing every removal through the console's audited path. Rejected because
-- it makes the ordinary operation fail with a foreign-key error rather than
-- doing the right thing, and an operator who meets that error will reach for
-- the dashboard's SQL editor, which is worse than where we started.
--
-- DELETING A PROFILE GOES THROUGH THE SANCTIONED PATH
--
-- The delete below cascades into security_events, whose guard refuses every
-- DELETE except one: it returns OLD when `venttly.purging_account` is 'on'.
-- admin_delete_user sets exactly that for the length of its transaction, so a
-- member's own login history is erased along with their account -- deliberate,
-- and asserted by 0026, because the login history is their personal data and
-- erasure is the point of a deletion request.
--
-- This migration is doing the same thing to two accountless profiles, so it
-- uses the same switch rather than inventing a second way in. The first
-- attempt at this file did not, and failed against production with
-- "security_events is append-only" -- which is how the separate, real defect
-- in 20261031090000 was found.
--
-- set_config(..., true) is transaction-local: it reverts at COMMIT whatever
-- happens, so the exception cannot outlive this migration.
--
-- THE DELETE IS FENCED
--
-- `DELETE … WHERE NOT EXISTS (SELECT FROM auth.users)` is one missing GRANT
-- away from deleting every member on the platform: if auth.users were empty or
-- unreadable to the executing role, every row would qualify. So the count is
-- taken first and the migration refuses to proceed if auth.users looks empty
-- or if the number of orphans is larger than the handful this is meant to
-- clear. A migration that finds the world in an unexpected state should stop,
-- not improvise.

BEGIN;

DO $$
DECLARE
  v_auth_total INTEGER;
  v_profiles   INTEGER;
  v_orphans    INTEGER;
  -- Well above the two known rows, far below anything that could be mistaken
  -- for the member base. If this is ever legitimately exceeded, the right move
  -- is to look at why, not to raise the number.
  v_ceiling CONSTANT INTEGER := 25;
BEGIN
  SELECT count(*) INTO v_auth_total FROM auth.users;
  SELECT count(*) INTO v_profiles   FROM public.users;

  -- An empty auth.users is only alarming next to profiles that claim to
  -- belong to it. Both empty is a database that has just been created --
  -- `supabase db reset`, CI, a new environment -- where there is nothing to
  -- delete and nothing to get wrong. The first version of this check refused
  -- on `v_auth_total = 0` alone and therefore could not be applied to a fresh
  -- database at all, which would have broken every reset from here on.
  IF v_auth_total = 0 AND v_profiles > 0 THEN
    RAISE EXCEPTION
      'refusing to run: auth.users is empty or unreadable while % profile '
      'row(s) exist, which would make every one of them look orphaned',
      v_profiles;
  END IF;

  SELECT count(*) INTO v_orphans
    FROM public.users p
    LEFT JOIN auth.users a ON a.id = p.user_id
   WHERE a.id IS NULL;

  IF v_orphans > v_ceiling THEN
    RAISE EXCEPTION
      'refusing to run: % profile rows have no auth account, expected at most %',
      v_orphans, v_ceiling;
  END IF;

  RAISE NOTICE 'deleting % orphaned profile row(s) of % auth accounts',
    v_orphans, v_auth_total;

  -- The one sanctioned reason an append-only security_events row may go: the
  -- account it belongs to is being erased. Transaction-local, so it lapses at
  -- COMMIT regardless of what happens below.
  PERFORM set_config('venttly.purging_account', 'on', true);

  DELETE FROM public.users p
   WHERE NOT EXISTS (SELECT 1 FROM auth.users a WHERE a.id = p.user_id);

  PERFORM set_config('venttly.purging_account', 'off', true);
END $$;

-- Idempotent: a re-run finds the constraint and leaves it alone. Named
-- explicitly rather than letting Postgres generate one, so the re-run check
-- and any future DROP refer to the same thing.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'users_user_id_auth_fkey'
       AND conrelid = 'public.users'::regclass
  ) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_user_id_auth_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE;
  END IF;
END $$;

COMMENT ON CONSTRAINT users_user_id_auth_fkey ON public.users IS
  'Deleting the Auth account deletes the profile, and through it the 103 '
  'foreign keys that already describe what removing a member means. Added '
  'after two staff invitations were deleted from the Auth side and left live '
  'profile rows behind, one of them an active moderator. prevent_legal_hold_'
  'user_delete still fires on the cascade and can veto it; audit_log has no '
  'foreign keys and is unaffected.';

SELECT public.record_migration(
  '20261032090000', 'users_auth_foreign_key'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
