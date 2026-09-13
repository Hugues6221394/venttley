-- A real, appealable enforcement notice against a test account.
--
-- Run in the Supabase SQL editor. Gives the appeals screen something to show
-- without inventing rows: the decision is taken through the ladder, so the
-- audit entry, the notice and the decision reference are all genuine and the
-- appeal path exercises the same code a real suspension would.
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

BEGIN;

-- Acting as tester_admin, so is_staff() passes and the audit trail records a
-- moderator rather than a superuser bypass.
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"b0de92d5-85e3-4fea-be66-55c5e4fdd5cc","role":"authenticated","aal":"aal2"}',
  true
);

SELECT public.admin_suspend_user_ladder(
  'a49e738f-fb1e-4c86-9c7b-485c9b14c595',
  'Test fixture: a suspension that can be appealed from the app. Not a real finding.'
);

SELECT public.admin_lift_suspension(
  'a49e738f-fb1e-4c86-9c7b-485c9b14c595',
  'Test fixture: reinstated immediately so the account stays usable.'
);

COMMIT;

-- What the app should now see for tester_user: one appealable account
-- suspension carrying a decision reference, and one reinstatement that is not
-- appealable because there is nothing left to contest.
SELECT payload->>'action'                      AS action,
       payload->>'appealable'                  AS appealable,
       (payload->>'decision_ref') IS NOT NULL   AS has_decision_ref,
       payload->>'reason'                       AS reason
  FROM public.notifications
 WHERE user_id = 'a49e738f-fb1e-4c86-9c7b-485c9b14c595'
   AND kind = 'moderation_action'
 ORDER BY created_at DESC;

SELECT account_status, suspension_count
  FROM public.users
 WHERE user_id = 'a49e738f-fb1e-4c86-9c7b-485c9b14c595';
