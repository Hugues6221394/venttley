BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(7);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('ddd10000-0000-4000-8000-000000000001','gsuper','gsuper','x',
        'gsuper','gsuper','gsuper','super_admin','active',1990),
       ('ddd10000-0000-4000-8000-000000000002','gmod','gmod','x',
        'gmod','gmod','gmod','moderator','active',1990),
       ('ddd10000-0000-4000-8000-000000000003','gmember','gmember','x',
        'gmember','gmember','gmember','normal','active',1995);

INSERT INTO public.posts (post_id, author_id, content, category_name, post_mood)
VALUES ('ddd20000-0000-4000-8000-000000000001','ddd10000-0000-4000-8000-000000000003',
        'a distinctive phrase about pineapples','vent_zone','healing');

INSERT INTO public.csam_incidents (incident_id, kind, content_ref, author_id, status)
VALUES ('ddd30000-0000-4000-8000-000000000001','post',
        'ddd20000-0000-4000-8000-000000000001','ddd10000-0000-4000-8000-000000000003','detected');

SET session_replication_role = origin;

SET LOCAL role authenticated;

-- ---------------------------------------------------------------------------
-- Anti-enumeration. A pseudonymous platform must not ship a box that walks
-- its member list a letter at a time.
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}', true);

SELECT throws_ok(
  $$SELECT * FROM public.admin_global_search('gme', 8)$$,
  'P0001', 'search needs at least 4 characters',
  'a query shorter than four characters is refused'
);

SELECT ok(
  (SELECT bool_or(id = 'ddd10000-0000-4000-8000-000000000003'::uuid)
     FROM public.admin_global_search('gmember', 8) WHERE kind = 'user'),
  'a pseudonym prefix finds the member'
);

-- Asserts this fixture's row is found, not a global count: the same phrase may
-- exist in other rows, and a count only passes on a pristine database.
SELECT ok(
  (SELECT bool_or(id = 'ddd20000-0000-4000-8000-000000000001'::uuid)
     FROM public.admin_global_search('pineapples', 8) WHERE kind = 'post'),
  'post text is searchable'
);

-- An id is matched exactly or not at all, so ids cannot be guessed by prefix.
SELECT is(
  (SELECT count(*)::int
     FROM public.admin_global_search('ddd20000-0000-4000-8000', 8)),
  0, 'a partial id matches nothing — ids are never prefix-matched'
);

-- ---------------------------------------------------------------------------
-- Role scoping, applied inside the query rather than filtered afterwards, so
-- a role cannot even learn that a restricted record exists for an id.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT count(*)::int
     FROM public.admin_global_search('ddd20000-0000-4000-8000-000000000001', 8)
    WHERE kind = 'csam_incident'),
  1, 'a super admin pasting the post id also sees the CSAM incident'
);

SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}', true);

SELECT is(
  (SELECT count(*)::int
     FROM public.admin_global_search('ddd20000-0000-4000-8000-000000000001', 8)
    WHERE kind = 'csam_incident'),
  0, 'a moderator pasting the same id is not told an incident exists'
);

-- A member is not staff and gets nothing, not a filtered view.
SELECT set_config('request.jwt.claims',
  '{"sub":"ddd10000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal1"}', true);

SELECT throws_ok(
  $$SELECT * FROM public.admin_global_search('gmember', 8)$$,
  'P0001', 'forbidden',
  'a member cannot search the console at all'
);

RESET role;

SELECT * FROM finish();
ROLLBACK;
