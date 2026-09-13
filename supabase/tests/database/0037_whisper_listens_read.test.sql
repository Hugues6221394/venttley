-- Who may read whisper_listens, and who needs to.
--
-- This file exists because a grant went missing for four days and nothing
-- noticed. 20261019090000 revoked SELECT on whisper_listens from
-- authenticated, and list_unheard_whispers and whispers_for_me both read it as
-- the caller, so both raised 42501 for every signed-in member. The client
-- degrades instead of crashing — it logs and falls back to plain recency — so
-- the rail kept showing something, and what it showed was wrong for everyone.
--
-- The pgTAP suite could not have caught it as written, because these functions
-- were only ever exercised as the owner, for whom no grant is required. That
-- is the lesson worth encoding: a privilege test that does not SET ROLE tests
-- nothing about privileges. Every assertion below runs as `authenticated` with
-- a real claim.
--
-- The policy is asserted as tightly as the grant. Restoring SELECT without
-- narrowing `USING (true)` would have traded a broken rail for a register of
-- who listened to which Whisper, readable by any member — which on this app is
-- the worse of the two by a wide margin.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(9);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('eee10000-0000-4000-8000-000000000001','wlme','wlme','x',
        'wlme','wlme','wlme','normal','active',1995),
       ('eee10000-0000-4000-8000-000000000002','wlother','wlother','x',
        'wlother','wlother','wlother','normal','active',1995);

INSERT INTO public.whispers (whisper_id, author_id, audio_path, audio_url,
                             audio_duration_seconds, category_name, voice_filter)
VALUES ('eee20000-0000-4000-8000-000000000001','eee10000-0000-4000-8000-000000000002',
        'whispers/a.m4a', 'https://example.invalid/a.m4a', 12, 'vent_zone', 'none'),
       ('eee20000-0000-4000-8000-000000000002','eee10000-0000-4000-8000-000000000002',
        'whispers/b.m4a', 'https://example.invalid/b.m4a', 9, 'vent_zone', 'none');

-- One each, so "mine" and "not mine" are both non-empty. Without the second
-- row an over-permissive policy passes every assertion.
INSERT INTO public.whisper_listens (whisper_id, listener_id)
VALUES ('eee20000-0000-4000-8000-000000000001','eee10000-0000-4000-8000-000000000001'),
       ('eee20000-0000-4000-8000-000000000002','eee10000-0000-4000-8000-000000000002');

SET session_replication_role = origin;

-- ---------------------------------------------------------------------------
-- The grant. This is the whole regression, stated directly.
-- ---------------------------------------------------------------------------

SELECT ok(
  has_table_privilege('authenticated', 'public.whisper_listens', 'SELECT'),
  'authenticated can SELECT whisper_listens — two functions read it as the caller'
);

SELECT ok(
  NOT has_table_privilege('authenticated', 'public.whisper_listens', 'INSERT'),
  'and cannot write to it directly; record_whisper_listen is the only way in'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.whisper_listens', 'SELECT'),
  'a signed-out caller gets nothing'
);

-- ---------------------------------------------------------------------------
-- The policy. Asserted as a real member, because a privilege test run as the
-- owner proves nothing — which is exactly how this was missed.
-- ---------------------------------------------------------------------------

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"eee10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);

SELECT is(
  (SELECT count(*)::int FROM public.whisper_listens),
  1, 'a member sees their own listen'
);

SELECT is(
  (SELECT count(*)::int FROM public.whisper_listens
    WHERE listener_id <> 'eee10000-0000-4000-8000-000000000001'),
  0,
  'and none of anybody else''s — a public register of who listened to what '
  'would undo the anonymity the feature exists to provide'
);

-- The two functions that broke. Both run as the caller; both only read the
-- caller's own rows.
SELECT lives_ok(
  'SELECT * FROM public.list_unheard_whispers(5)',
  'list_unheard_whispers runs for a member instead of raising 42501'
);

SELECT lives_ok(
  'SELECT * FROM public.whispers_for_me(5)',
  'and so does whispers_for_me'
);

-- The exclusion has to actually work, or the grant is restored and the feature
-- still does not do its job.
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM public.list_unheard_whispers(50) w
     WHERE w.whisper_id = 'eee20000-0000-4000-8000-000000000001'
  ),
  'a Whisper this member has already heard is not offered again'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.list_unheard_whispers(50) w
     WHERE w.whisper_id = 'eee20000-0000-4000-8000-000000000002'
  ),
  'one only somebody else has heard still is — the filter is per listener, '
  'not global'
);

RESET role;

SELECT * FROM finish();
ROLLBACK;
