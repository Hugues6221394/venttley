BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(16);

-- ---------------------------------------------------------------------------
-- Fixtures. session_replication_role = replica bypasses the app's own content
-- write guards (age verification, rate limits), which are not what this file
-- is testing; it is restored before anything that must exercise a trigger.
-- ---------------------------------------------------------------------------
SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status)
VALUES ('aaaa0000-0000-4000-8000-000000000001', 'casemod', 'casemod', 'x',
        'casemod', 'casemod', 'casemod', 'moderator', 'active'),
       ('aaaa0000-0000-4000-8000-000000000002', 'caseauthor', 'caseauthor', 'x',
        'caseauthor', 'caseauthor', 'caseauthor', 'normal', 'active'),
       ('aaaa0000-0000-4000-8000-000000000003', 'casereporter1', 'casereporter1', 'x',
        'casereporter1', 'casereporter1', 'casereporter1', 'normal', 'active'),
       ('aaaa0000-0000-4000-8000-000000000004', 'casereporter2', 'casereporter2', 'x',
        'casereporter2', 'casereporter2', 'casereporter2', 'normal', 'active'),
       ('aaaa0000-0000-4000-8000-000000000005', 'casesupport', 'casesupport', 'x',
        'casesupport', 'casesupport', 'casesupport', 'support', 'active');

INSERT INTO public.posts (post_id, author_id, content, category_name, post_mood)
VALUES ('bbbb0000-0000-4000-8000-000000000001',
        'aaaa0000-0000-4000-8000-000000000002',
        'the content as originally posted', 'vent_zone', 'healing');

INSERT INTO public.chat_rooms (room_id, created_by)
VALUES ('cccc0000-0000-4000-8000-000000000001', 'aaaa0000-0000-4000-8000-000000000002');
INSERT INTO public.chat_messages (message_id, room_id, sender_id, encrypted_payload, nonce_iv)
VALUES ('dddd0000-0000-4000-8000-000000000001', 'cccc0000-0000-4000-8000-000000000001',
        'aaaa0000-0000-4000-8000-000000000002', 'ciphertext-sentinel', 'iv');

SET session_replication_role = origin;

-- ---------------------------------------------------------------------------
-- A report opens a case
-- ---------------------------------------------------------------------------
INSERT INTO public.reports (post_id, reporter_id, reason)
VALUES ('bbbb0000-0000-4000-8000-000000000001',
        'aaaa0000-0000-4000-8000-000000000003', 'spam');

SELECT is(
  (SELECT count(*)::int FROM public.moderation_cases
    WHERE target_id = 'bbbb0000-0000-4000-8000-000000000001'),
  1, 'a report opens exactly one case'
);

SELECT is(
  (SELECT severity FROM public.moderation_cases
    WHERE target_id = 'bbbb0000-0000-4000-8000-000000000001'),
  'low', 'a spam report opens at low severity'
);

SELECT is(
  (SELECT subject_id FROM public.moderation_cases
    WHERE target_id = 'bbbb0000-0000-4000-8000-000000000001'),
  'aaaa0000-0000-4000-8000-000000000002'::uuid,
  'the case resolves the subject from the content author'
);

SELECT isnt(
  (SELECT evidence_hash FROM public.moderation_cases
    WHERE target_id = 'bbbb0000-0000-4000-8000-000000000001'),
  NULL, 'the evidence snapshot is hashed so tampering is detectable'
);

-- ---------------------------------------------------------------------------
-- Deduplication: a second report joins rather than opening a second case
-- ---------------------------------------------------------------------------
INSERT INTO public.reports (post_id, reporter_id, reason)
VALUES ('bbbb0000-0000-4000-8000-000000000001',
        'aaaa0000-0000-4000-8000-000000000004', 'harassment');

SELECT is(
  (SELECT count(*)::int FROM public.moderation_cases
    WHERE target_id = 'bbbb0000-0000-4000-8000-000000000001'),
  1, 'a second report about the same target does not open a second case'
);

SELECT is(
  (SELECT report_count FROM public.moderation_cases
    WHERE target_id = 'bbbb0000-0000-4000-8000-000000000001'),
  2, 'the case counts both reports'
);

SELECT is(
  (SELECT severity FROM public.moderation_cases
    WHERE target_id = 'bbbb0000-0000-4000-8000-000000000001'),
  'elevated', 'a more serious second report raises severity'
);

-- Raising severity has to pull the deadline in, or a case that became
-- serious keeps the lenient deadline it was given when it looked routine.
SELECT ok(
  (SELECT sla_due_at - opened_at FROM public.moderation_cases
    WHERE target_id = 'bbbb0000-0000-4000-8000-000000000001') <= interval '60 minutes',
  'raising severity tightens the SLA deadline rather than leaving it'
);

-- ---------------------------------------------------------------------------
-- Evidence is a snapshot, not a live read
-- ---------------------------------------------------------------------------
SET session_replication_role = replica;
UPDATE public.posts SET content = 'edited after the report', deleted_at = now()
 WHERE post_id = 'bbbb0000-0000-4000-8000-000000000001';
SET session_replication_role = origin;

SELECT is(
  (SELECT evidence->>'content' FROM public.moderation_cases
    WHERE target_id = 'bbbb0000-0000-4000-8000-000000000001'),
  'the content as originally posted',
  'the snapshot still holds what was reported after the content is edited away'
);

-- ---------------------------------------------------------------------------
-- Private messages: metadata only
-- ---------------------------------------------------------------------------
INSERT INTO public.reports (target_chat_message_id, reporter_id, reason)
VALUES ('dddd0000-0000-4000-8000-000000000001',
        'aaaa0000-0000-4000-8000-000000000003', 'harassment');

SELECT ok(
  (SELECT evidence::text NOT LIKE '%ciphertext-sentinel%'
     FROM public.moderation_cases
    WHERE target_id = 'dddd0000-0000-4000-8000-000000000001'),
  'a reported DM never copies the message body into the case'
);

-- ---------------------------------------------------------------------------
-- History is append-only
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.moderation_case_events SET note = 'tampered'
     WHERE event_id = (SELECT event_id FROM public.moderation_case_events LIMIT 1)$$,
  'P0001', 'moderation_case_events rows are immutable (op: UPDATE)',
  'case history rows cannot be edited'
);

SELECT throws_ok(
  $$DELETE FROM public.moderation_case_events
     WHERE event_id = (SELECT event_id FROM public.moderation_case_events LIMIT 1)$$,
  'P0001', 'moderation_case_events rows are immutable (op: DELETE)',
  'case history rows cannot be deleted'
);

-- ---------------------------------------------------------------------------
-- Decisions
-- ---------------------------------------------------------------------------
-- Resolve the ids first: `authenticated` has no direct SELECT grant on
-- moderation_cases (same posture as reports and csam_incidents — reads go
-- through admin_case_queue or the service-role client), so these lookups
-- cannot run inside the role-switched block below.
SELECT case_id AS post_case_id FROM public.moderation_cases
 WHERE target_id = 'bbbb0000-0000-4000-8000-000000000001' \gset
SELECT case_id AS dm_case_id FROM public.moderation_cases
 WHERE target_id = 'dddd0000-0000-4000-8000-000000000001' \gset

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"aaaa0000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);

-- A decision that affects a member is the thing an appeal argues with, so it
-- must carry a reason from the start rather than be reconstructed later.
SELECT throws_ok(
  format($$SELECT public.admin_decide_case(%L, 'content_removed', 'POL-1', '')$$,
         :'post_case_id'),
  'P0001', 'a decision that affects a member requires a note',
  'an impactful decision without a note is refused'
);

SELECT lives_ok(
  format($$SELECT public.admin_decide_case(%L, 'content_removed', 'POL-1', 'removed under policy')$$,
         :'post_case_id'),
  'a decision with a note is accepted'
);

RESET role;

-- Closing the case closes the reports that fed it; leaving them open would
-- strand the same work in the old queue.
SELECT is(
  (SELECT count(*)::int FROM public.reports
    WHERE post_id = 'bbbb0000-0000-4000-8000-000000000001' AND is_resolved = false),
  0, 'deciding a case resolves the reports that fed it'
);

-- ---------------------------------------------------------------------------
-- Support may read the queue but not decide
-- ---------------------------------------------------------------------------
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"aaaa0000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1"}', true);

SELECT throws_ok(
  format($$SELECT public.admin_decide_case(%L, 'no_action', NULL, 'support decision')$$,
         :'dm_case_id'),
  'P0001', 'forbidden',
  'support can triage the queue but cannot decide a case'
);

RESET role;

SELECT * FROM finish();
ROLLBACK;
