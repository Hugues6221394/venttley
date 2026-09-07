BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(10);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('9999aaaa-0000-4000-8000-000000000001','enactmod','enactmod','x',
        'enactmod','enactmod','enactmod','moderator','active',1990),
       -- Already suspended: removing this author's content is the case that
       -- would break if the content write guard fired on a deleted_at update.
       ('9999aaaa-0000-4000-8000-000000000002','enactsusp','enactsusp','x',
        'enactsusp','enactsusp','enactsusp','normal','suspended',1990),
       ('9999aaaa-0000-4000-8000-000000000003','enactrep','enactrep','x',
        'enactrep','enactrep','enactrep','normal','active',1990),
       ('9999aaaa-0000-4000-8000-000000000004','enactdm','enactdm','x',
        'enactdm','enactdm','enactdm','normal','active',1990),
       ('9999aaaa-0000-4000-8000-000000000005','enactshadow','enactshadow','x',
        'enactshadow','enactshadow','enactshadow','normal','active',1990);

INSERT INTO public.posts (post_id, author_id, content, category_name, post_mood)
VALUES ('9999bbbb-0000-4000-8000-000000000001','9999aaaa-0000-4000-8000-000000000002',
        'content by a suspended author','vent_zone','healing'),
       ('9999bbbb-0000-4000-8000-000000000002','9999aaaa-0000-4000-8000-000000000005',
        'content for the shadow case','vent_zone','healing');

INSERT INTO public.chat_rooms (room_id, created_by)
VALUES ('9999cccc-0000-4000-8000-000000000001','9999aaaa-0000-4000-8000-000000000004');
INSERT INTO public.chat_messages (message_id, room_id, sender_id, encrypted_payload, nonce_iv)
VALUES ('9999dddd-0000-4000-8000-000000000001','9999cccc-0000-4000-8000-000000000001',
        '9999aaaa-0000-4000-8000-000000000004','dm-body-sentinel','iv');

SET session_replication_role = origin;

INSERT INTO public.reports (post_id, reporter_id, reason)
VALUES ('9999bbbb-0000-4000-8000-000000000001','9999aaaa-0000-4000-8000-000000000003','harassment'),
       ('9999bbbb-0000-4000-8000-000000000002','9999aaaa-0000-4000-8000-000000000003','harassment');
INSERT INTO public.reports (target_chat_message_id, reporter_id, reason)
VALUES ('9999dddd-0000-4000-8000-000000000001','9999aaaa-0000-4000-8000-000000000003','harassment');

SELECT case_id AS susp_case FROM public.moderation_cases
 WHERE target_id = '9999bbbb-0000-4000-8000-000000000001' \gset
SELECT case_id AS shadow_case FROM public.moderation_cases
 WHERE target_id = '9999bbbb-0000-4000-8000-000000000002' \gset
SELECT case_id AS dm_case FROM public.moderation_cases
 WHERE target_id = '9999dddd-0000-4000-8000-000000000001' \gset

-- ---------------------------------------------------------------------------
-- DM bodies: captured, but not in the queue projection
-- ---------------------------------------------------------------------------
SELECT ok(
  (SELECT evidence::text NOT LIKE '%dm-body-sentinel%'
     FROM public.moderation_cases WHERE case_id = :'dm_case'),
  'the DM body is not in the evidence blob the queue returns'
);

SELECT is(
  (SELECT sensitive_evidence->>'body' FROM public.moderation_cases WHERE case_id = :'dm_case'),
  'dm-body-sentinel',
  'the DM body is captured, in the separately-gated column'
);

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"9999aaaa-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);

SELECT ok(
  (SELECT bool_and(evidence::text NOT LIKE '%dm-body-sentinel%')
     FROM public.admin_case_queue('unresolved', NULL, 100)),
  'admin_case_queue never returns a DM body to any role that can call it'
);

-- Reading it is a separate act, and one that leaves a trace.
SELECT is(
  (SELECT public.admin_read_case_sensitive_evidence(:'dm_case', 'reviewing report')->>'body'),
  'dm-body-sentinel', 'the gated accessor returns the body'
);

RESET role;

SELECT is(
  (SELECT count(*)::int FROM public.moderation_case_events
    WHERE case_id = :'dm_case' AND kind = 'evidence_accessed'),
  1, 'reading sensitive evidence is recorded in the case history'
);

SELECT is(
  (SELECT count(*)::int FROM public.audit_log
    WHERE target_id = :'dm_case' AND action = 'case.read_sensitive_evidence'),
  1, 'reading sensitive evidence is recorded in the audit log'
);

-- ---------------------------------------------------------------------------
-- Decisions are carried out, not merely recorded
-- ---------------------------------------------------------------------------
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"9999aaaa-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);

SELECT lives_ok(
  format($$SELECT public.admin_decide_case(%L,'content_removed','POL-1','removing')$$, :'susp_case'),
  'content can be removed even when its author is already suspended'
);

SELECT lives_ok(
  format($$SELECT public.admin_decide_case(%L,'user_shadow_restricted','POL-2','shadow restricting')$$, :'shadow_case'),
  'a shadow-restriction decision is accepted'
);

RESET role;

SELECT ok(
  (SELECT deleted_at IS NOT NULL FROM public.posts
    WHERE post_id = '9999bbbb-0000-4000-8000-000000000001'),
  'deciding content_removed actually removes the content, not just the record of it'
);

-- Shadow restriction has to land on users.shadow_banned, the value the read
-- paths actually consult — account_status has no 'shadow_banned' member.
SELECT ok(
  (SELECT shadow_banned FROM public.users
    WHERE user_id = '9999aaaa-0000-4000-8000-000000000005'),
  'deciding user_shadow_restricted sets the boolean the read paths consult'
);

SELECT * FROM finish();
ROLLBACK;
