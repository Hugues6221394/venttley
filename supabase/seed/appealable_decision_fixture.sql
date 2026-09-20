-- A real, appealable enforcement notice against a test account.
--
-- Gives the appeals screen something to show without inventing rows: the
-- decision is taken through the ladder, so the audit entry, the notice and the
-- decision reference are all genuine and the appeal path exercises the same
-- code a real suspension would.
--
-- The account is reinstated in the same transaction, so it stays usable for
-- testing. The notice survives and stays appealable for 30 days.
--
-- Side effects, all intended:
--   * tester_user is signed out everywhere (the ladder deletes auth.sessions).
--   * tester_user.suspension_count goes to 1, so a later ladder suspension on
--     that account would start at the 7-day tier rather than 24 hours.
--   * Two audit_log entries and two notifications, attributed to tester_admin.
--
-- Not for a real account. Wipe with the rest of the seed data before launch.
--
-- Accounts are resolved by pseudonym, not by id. This file used to hardcode
-- two production UUIDs, and test_accounts.sql creates its accounts with
-- gen_random_uuid() -- so the ids only ever matched the one database they were
-- copied from. Against a freshly reset local database the ids did not exist,
-- is_staff() saw a stranger, and the whole thing died on "forbidden". The
-- visible symptom was integration_test/appeals_flow_test failing with "no
-- enforcement notices came back", which reads like an RLS regression and is
-- not one: after any `supabase db reset` the standard device pass could not
-- be run at all until this was re-seeded, and it could not be re-seeded.

BEGIN;

DO $$
DECLARE
  v_admin  UUID;
  v_member UUID;
BEGIN
  SELECT user_id INTO v_admin
    FROM public.users WHERE anonymous_pseudonym = 'tester_admin';
  SELECT user_id INTO v_member
    FROM public.users WHERE anonymous_pseudonym = 'tester_user';

  IF v_admin IS NULL OR v_member IS NULL THEN
    RAISE EXCEPTION
      'seed accounts missing (tester_admin=%, tester_user=%). Apply '
      'supabase/seed/test_accounts.sql first.',
      COALESCE(v_admin::text, 'absent'), COALESCE(v_member::text, 'absent');
  END IF;

  -- Acting as tester_admin, so is_staff() passes and the audit trail records a
  -- moderator rather than a superuser bypass. aal2 because the ladder and the
  -- lift both require a stepped-up session.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub',  v_admin,
      'role', 'authenticated',
      'aal',  'aal2'
    )::text,
    true
  );

  PERFORM public.admin_suspend_user_ladder(
    v_member,
    'Test fixture: a suspension that can be appealed from the app. Not a real finding.'
  );

  PERFORM public.admin_lift_suspension(
    v_member,
    'Test fixture: reinstated immediately so the account stays usable.'
  );
END $$;

COMMIT;

-- What the app should now see for tester_user: one appealable account
-- suspension carrying a decision reference, and one reinstatement that is not
-- appealable because there is nothing left to contest.
SELECT n.payload->>'action'                     AS action,
       n.payload->>'appealable'                 AS appealable,
       (n.payload->>'decision_ref') IS NOT NULL AS has_decision_ref,
       n.payload->>'reason'                     AS reason
  FROM public.notifications n
  JOIN public.users u ON u.user_id = n.user_id
 WHERE u.anonymous_pseudonym = 'tester_user'
   AND n.kind = 'moderation_action'
 ORDER BY n.created_at DESC;

SELECT account_status, suspension_count
  FROM public.users
 WHERE anonymous_pseudonym = 'tester_user';
