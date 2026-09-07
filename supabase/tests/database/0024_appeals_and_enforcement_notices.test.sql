BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(15);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('ccc10000-0000-4000-8000-000000000001','apmoda','apmoda','x',
        'apmoda','apmoda','apmoda','moderator','active',1990),
       ('ccc10000-0000-4000-8000-000000000002','apmodb','apmodb','x',
        'apmodb','apmodb','apmodb','moderator','active',1990),
       ('ccc10000-0000-4000-8000-000000000003','apmember','apmember','x',
        'apmember','apmember','apmember','normal','active',1995),
       ('ccc10000-0000-4000-8000-000000000004','apreporter','apreporter','x',
        'apreporter','apreporter','apreporter','normal','active',1995),
       ('ccc10000-0000-4000-8000-000000000005','apshadow','apshadow','x',
        'apshadow','apshadow','apshadow','normal','active',1995);

INSERT INTO public.posts (post_id, author_id, content, category_name, post_mood)
VALUES ('ccc20000-0000-4000-8000-000000000001','ccc10000-0000-4000-8000-000000000003',
        'the disputed post','vent_zone','healing'),
       ('ccc20000-0000-4000-8000-000000000002','ccc10000-0000-4000-8000-000000000005',
        'the shadow case','vent_zone','healing');

SET session_replication_role = origin;

INSERT INTO public.reports (post_id, reporter_id, reason)
VALUES ('ccc20000-0000-4000-8000-000000000001','ccc10000-0000-4000-8000-000000000004','harassment'),
       ('ccc20000-0000-4000-8000-000000000002','ccc10000-0000-4000-8000-000000000004','harassment');

SELECT case_id AS post_case FROM public.moderation_cases
 WHERE target_id = 'ccc20000-0000-4000-8000-000000000001' \gset
SELECT case_id AS shadow_case FROM public.moderation_cases
 WHERE target_id = 'ccc20000-0000-4000-8000-000000000002' \gset

-- ---------------------------------------------------------------------------
-- The member has to be told, or an appeal is a door nobody knows exists.
-- Before this, no enforcement path wrote anything a member could see.
-- ---------------------------------------------------------------------------
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);
SELECT public.admin_decide_case(:'post_case','content_removed','POL-1',
  'Your post targeted another member.');
SELECT public.admin_decide_case(:'shadow_case','user_shadow_restricted','POL-2',
  'Shadow restricted.');
RESET role;

SELECT is(
  (SELECT count(*)::int FROM public.notifications
    WHERE user_id = 'ccc10000-0000-4000-8000-000000000003'
      AND kind = 'moderation_action'),
  1, 'a decision notifies the member exactly once'
);

SELECT is(
  (SELECT payload->>'appealable' FROM public.notifications
    WHERE user_id = 'ccc10000-0000-4000-8000-000000000003' LIMIT 1),
  'true', 'the notice tells the member the decision can be appealed'
);

-- Reporter privacy has already cost this project a bug (f71d9c2).
SELECT ok(
  (SELECT bool_and(payload::text NOT LIKE '%apreporter%'
                   AND payload::text NOT LIKE '%ccc10000-0000-4000-8000-000000000004%')
     FROM public.notifications
    WHERE user_id = 'ccc10000-0000-4000-8000-000000000003'),
  'the notice never reveals who reported'
);

-- A shadow restriction the member cannot be told about must send nothing,
-- for the same reason it does not revoke their sessions.
SELECT is(
  (SELECT count(*)::int FROM public.notifications
    WHERE user_id = 'ccc10000-0000-4000-8000-000000000005'),
  0, 'a shadow restriction notifies nobody — a notice would defeat it'
);

-- ---------------------------------------------------------------------------
-- Who may appeal
-- ---------------------------------------------------------------------------
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000004","role":"authenticated","aal":"aal1"}', true);

-- A case id in someone else's hands must not become a way to act on a
-- decision about a third party.
SELECT throws_ok(
  format($$SELECT public.submit_appeal(%L, 'not my decision')$$, :'post_case'),
  'P0001', 'forbidden: only the subject of a decision may appeal it',
  'a member who is not the subject cannot appeal'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1"}', true);
SELECT throws_ok(
  format($$SELECT public.submit_appeal(%L, 'let me contest this')$$, :'shadow_case'),
  'P0001', 'this decision is not appealable',
  'a shadow restriction cannot be appealed, matching the silence about it'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}', true);
SELECT lives_ok(
  format($$SELECT public.submit_appeal(%L, 'This was a reply, not an attack.')$$, :'post_case'),
  'the subject of a decision can appeal it'
);
RESET role;

SELECT appeal_id AS ap FROM public.moderation_appeals
 WHERE case_id = :'post_case' AND status = 'open' \gset

-- Appeal status has to be visible to the appellant, or it is another decision
-- taken about them that they cannot see.
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}', true);
SELECT is(
  (SELECT count(*)::int FROM public.moderation_appeals),
  1, 'a member can read their own appeal, and only their own'
);
RESET role;

-- ---------------------------------------------------------------------------
-- Independence — the property the whole feature rests on
-- ---------------------------------------------------------------------------
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);
SELECT throws_ok(
  format($$SELECT public.admin_decide_appeal(%L,'upheld','my call stands')$$, :'ap'),
  'P0001', NULL,
  'the moderator who decided cannot review the appeal against their own decision'
);

SELECT throws_ok(
  format($$SELECT public.admin_decide_appeal(%L,'overturned','')$$, :'ap'),
  'P0001', 'an appeal outcome requires a note: it is what the member is told',
  'an appeal outcome without a note is refused'
);

-- A different moderator overturns it.
SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}', true);
SELECT lives_ok(
  format($$SELECT public.admin_decide_appeal(%L,'overturned','Context shows a response, not an attack.')$$, :'ap'),
  'an independent moderator can decide the appeal'
);
RESET role;

-- An upheld appeal that changes nothing is the same defect as a decision that
-- records without enacting: the record says the member won, and their content
-- is still gone.
SELECT ok(
  (SELECT deleted_at IS NULL FROM public.posts
    WHERE post_id = 'ccc20000-0000-4000-8000-000000000001'),
  'overturning a removal actually restores the content'
);

SELECT is(
  (SELECT payload->>'action' FROM public.notifications
    WHERE user_id = 'ccc10000-0000-4000-8000-000000000003'
      AND payload->>'action' LIKE 'appeal%' LIMIT 1),
  'appeal_overturned', 'the member is told the appeal outcome'
);

-- ---------------------------------------------------------------------------
-- Finality
-- ---------------------------------------------------------------------------
SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"ccc10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}', true);

-- The partial unique index cannot express this: a decided appeal vacates the
-- status='open' slot, so without an explicit check a member could re-appeal
-- an upheld decision indefinitely.
SELECT throws_ok(
  format($$SELECT public.submit_appeal(%L, 'again please')$$, :'post_case'),
  'P0001', 'this decision has already been through appeal; that outcome is final at this tier',
  'a decision that has been through appeal cannot be appealed again'
);
RESET role;

SELECT is(
  (SELECT count(*)::int FROM public.audit_log WHERE action = 'appeal.overturned'),
  1, 'the appeal outcome is in the privileged audit log'
);

SELECT * FROM finish();
ROLLBACK;
