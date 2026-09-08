BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(6);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('eee10000-0000-4000-8000-000000000001','sloadmin','sloadmin','x',
        'sloadmin','sloadmin','sloadmin','super_admin','active',1990),
       ('eee10000-0000-4000-8000-000000000002','sloanalyst','sloanalyst','x',
        'sloanalyst','sloanalyst','sloanalyst','analyst','active',1990),
       ('eee10000-0000-4000-8000-000000000003','slomember','slomember','x',
        'slomember','slomember','slomember','normal','active',1995),
       ('eee10000-0000-4000-8000-000000000004','sloreporter','sloreporter','x',
        'sloreporter','sloreporter','sloreporter','normal','active',1995);

INSERT INTO public.posts (post_id, author_id, content, category_name, post_mood)
VALUES ('eee20000-0000-4000-8000-000000000001','eee10000-0000-4000-8000-000000000003',
        'slo fixture','vent_zone','healing');

SET session_replication_role = origin;

INSERT INTO public.reports (post_id, reporter_id, reason)
VALUES ('eee20000-0000-4000-8000-000000000001','eee10000-0000-4000-8000-000000000004','harassment');

SET LOCAL role authenticated;

-- ---------------------------------------------------------------------------
-- Who may read it. These are aggregates with no authored content, so the
-- analyst tier belongs here — but a member does not.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);

SELECT ok(
  (SELECT count(*) FROM public.admin_moderation_slo(30)) > 0,
  'a super admin gets metrics back'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}', true);

SELECT ok(
  (SELECT count(*) FROM public.admin_moderation_slo(30)) > 0,
  'an analyst gets metrics back — same tier as /analytics and /ops'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}', true);

SELECT throws_ok(
  $$SELECT * FROM public.admin_moderation_slo(30)$$,
  'P0001', 'forbidden',
  'a member cannot read the service-level metrics'
);

-- ---------------------------------------------------------------------------
-- The distinction the page depends on: a rate needs a sample before it means
-- anything, an absolute count of a bad condition does not. Getting this wrong
-- rendered "0 jobs stuck" as unmeasured rather than as the good state.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);

SELECT ok(
  (SELECT bool_and(NOT needs_sample) FROM public.admin_moderation_slo(30)
    WHERE unit IN ('cases','jobs','messages','appeals')),
  'point-in-time counts are not gated on sample size'
);

SELECT ok(
  (SELECT bool_and(needs_sample) FROM public.admin_moderation_slo(30)
    WHERE metric LIKE '%p90%' OR metric LIKE '%p50%'),
  'percentiles are gated on sample size'
);

-- ---------------------------------------------------------------------------
-- A breach is actually detected, not just reported as zero.
-- ---------------------------------------------------------------------------
RESET role;
UPDATE public.moderation_cases
   SET sla_due_at = now() - interval '3 hours', opened_at = now() - interval '4 hours'
 WHERE target_id = 'eee20000-0000-4000-8000-000000000001';

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);

SELECT is(
  (SELECT met FROM public.admin_moderation_slo(30) WHERE metric = 'Open past SLA'),
  false,
  'an unresolved case past its deadline is reported as a missed target'
);

RESET role;

SELECT * FROM finish();
ROLLBACK;
