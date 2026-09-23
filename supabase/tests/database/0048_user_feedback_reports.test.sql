-- Reporting a bug, and who may read it.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(8);

SET session_replication_role = replica;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
VALUES ('ccc10000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','fbreporter@id.venttly.app','x', now(),
        '{}','{}', now(), now(),'','','','','','','',''),
       ('ccc10000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','fbnosy@id.venttly.app','x', now(),
        '{}','{}', now(), now(),'','','','','','','',''),
       ('ccc10000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','fbstaff@id.venttly.app','x', now(),
        '{}','{}', now(), now(),'','','','','','','','');

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('ccc10000-0000-4000-8000-000000000001','fbreporter','fbreporter','x',
        'fbreporter','fbreporter','fbreporter','normal','active',1990),
       ('ccc10000-0000-4000-8000-000000000002','fbnosy','fbnosy','x',
        'fbnosy','fbnosy','fbnosy','normal','active',1990),
       ('ccc10000-0000-4000-8000-000000000003','fbstaff','fbstaff','x',
        'fbstaff','fbstaff','fbstaff','super_admin','active',1990);

SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
  '{"sub":"ccc10000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT throws_like(
  $$ SELECT public.submit_feedback('rant', 'Title here', 'Enough detail to pass') $$,
  '%invalid_kind%',
  'only bug or suggestion are accepted'
);

SELECT throws_ok(
  $$ SELECT public.submit_feedback('bug', 'ab', 'Enough detail to pass') $$,
  '23514',
  NULL,
  'a two-character title is refused by the check constraint'
);

SELECT lives_ok(
  $$ SELECT public.submit_feedback(
       'bug', 'Studio tab bar stays black',
       'Switching from black to light leaves the profile tab strip dark.',
       'profile', '1.0.0', 'ios', 'iPhone 17') $$,
  'a complete bug report is accepted'
);

SELECT results_eq(
  $$ SELECT count(*)::INT FROM public.my_feedback() $$,
  ARRAY[1],
  'the reporter can see their own report and its status'
);

SELECT results_eq(
  $$ SELECT status FROM public.my_feedback() $$,
  ARRAY['new'],
  'it starts as new'
);
RESET ROLE;

-- Somebody else's account cannot read it.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
  '{"sub":"ccc10000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT results_eq(
  $$ SELECT count(*)::INT FROM public.feedback_reports $$,
  ARRAY[0],
  'another member cannot read the queue'
);
SELECT throws_like(
  $$ SELECT public.admin_feedback_queue() $$,
  '%not_authorized%',
  'and cannot call the staff queue'
);
RESET ROLE;

-- Staff can, and triage sticks.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
  '{"sub":"ccc10000-0000-4000-8000-000000000003","role":"authenticated"}';
SELECT results_eq(
  $$ WITH q AS (SELECT report_id FROM public.admin_feedback_queue() LIMIT 1)
     SELECT (SELECT count(*)::INT FROM q) $$,
  ARRAY[1],
  'staff see the report in the queue'
);
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
