BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(4);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('aaab0000-0000-4000-8000-000000000001','holdsubject','holdsubject','x',
        'holdsubject','holdsubject','holdsubject','normal','active',1995),
       ('aaab0000-0000-4000-8000-000000000002','freesubject','freesubject','x',
        'freesubject','freesubject','freesubject','normal','active',1995),
       ('aaab0000-0000-4000-8000-000000000003','csamsubject','csamsubject','x',
        'csamsubject','csamsubject','csamsubject','normal','active',1995),
       ('aaab0000-0000-4000-8000-000000000004','holdreporter','holdreporter','x',
        'holdreporter','holdreporter','holdreporter','normal','active',1995);

INSERT INTO public.posts (post_id, author_id, content, category_name, post_mood)
VALUES ('aaab1111-0000-4000-8000-000000000001','aaab0000-0000-4000-8000-000000000001',
        'evidence to preserve','vent_zone','healing'),
       ('aaab1111-0000-4000-8000-000000000002','aaab0000-0000-4000-8000-000000000002',
        'nothing special','vent_zone','healing');

SET session_replication_role = origin;

INSERT INTO public.reports (post_id, reporter_id, reason)
VALUES ('aaab1111-0000-4000-8000-000000000001','aaab0000-0000-4000-8000-000000000004','harassment'),
       ('aaab1111-0000-4000-8000-000000000002','aaab0000-0000-4000-8000-000000000004','spam');

UPDATE public.moderation_cases SET legal_hold = true
 WHERE target_id = 'aaab1111-0000-4000-8000-000000000001';

-- The flag existed before this and enforced nothing: an operator could place a
-- case under hold, believe the evidence was safe, and the subject's account
-- could still be deleted out from under it.
SELECT throws_ok(
  $$DELETE FROM public.users WHERE user_id = 'aaab0000-0000-4000-8000-000000000001'$$,
  'P0001', NULL,
  'an account whose case is under legal hold cannot be deleted'
);

-- The error has to name the case, or the operator cannot find the hold to lift.
SELECT ok(
  (SELECT count(*)::int FROM public.moderation_cases
    WHERE subject_id = 'aaab0000-0000-4000-8000-000000000001' AND legal_hold) = 1,
  'the held case is still there after the refused delete'
);

-- Holding must not become a blanket block: an ordinary unresolved report is not
-- a preservation order, and treating it as one would refuse a member's own
-- deletion request over a spam flag.
SELECT lives_ok(
  $$DELETE FROM public.users WHERE user_id = 'aaab0000-0000-4000-8000-000000000002'$$,
  'an account with an open case but no legal hold is still deletable'
);

-- The narrower hold this function already enforced must not regress.
SET session_replication_role = replica;
INSERT INTO public.csam_incidents (incident_id, kind, content_ref, author_id, status)
VALUES (gen_random_uuid(), 'post', 'aaab1111-0000-4000-8000-000000000001',
        'aaab0000-0000-4000-8000-000000000003', 'detected');
SET session_replication_role = origin;

SELECT throws_ok(
  $$DELETE FROM public.users WHERE user_id = 'aaab0000-0000-4000-8000-000000000003'$$,
  'P0001', NULL,
  'the pre-existing open-CSAM-incident hold still blocks deletion'
);

SELECT * FROM finish();
ROLLBACK;
