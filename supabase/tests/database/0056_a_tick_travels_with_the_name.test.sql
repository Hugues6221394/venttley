-- The tick follows the person, not the screen.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(9);

SET session_replication_role = replica;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
SELECT v.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       v.id || '@id.venttly.app', 'x', now(), '{}', '{}',
       now() - INTERVAL '2 years', now(), '','','','','','','',''
  FROM (VALUES
    ('aab10000-0000-4000-8000-000000000001'::UUID),  -- looking
    ('aab10000-0000-4000-8000-000000000002'::UUID),  -- verified
    ('aab10000-0000-4000-8000-000000000003'::UUID)   -- not
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, is_verified, created_at)
VALUES
  ('aab10000-0000-4000-8000-000000000001','tickviewer','x','x','Viewer','viewer','tickviewer','normal','active',1990, FALSE, now() - INTERVAL '2 years'),
  ('aab10000-0000-4000-8000-000000000002','tickknown','x','x','Known Person','known person','tickknown','normal','active',1990, TRUE, now() - INTERVAL '2 years'),
  ('aab10000-0000-4000-8000-000000000003','tickplain','x','x','Plain Person','plain person','tickplain','normal','active',1990, FALSE, now() - INTERVAL '2 years');

INSERT INTO public.chat_rooms (room_id, initiated_by, received_by, room_status, room_kind)
VALUES ('aab1aaaa-0000-4000-8000-000000000001',
        'aab10000-0000-4000-8000-000000000001',
        'aab10000-0000-4000-8000-000000000002', 'active', 'direct'),
       ('aab1aaaa-0000-4000-8000-000000000002',
        'aab10000-0000-4000-8000-000000000001',
        'aab10000-0000-4000-8000-000000000003', 'active', 'direct');

INSERT INTO public.policy_acceptances (user_id, kind, version)
SELECT u.user_id, c.kind, c.version
  FROM public.users u, public.current_policies() c
ON CONFLICT DO NOTHING;

SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"aab10000-0000-4000-8000-000000000001","role":"authenticated"}';

-- The inbox is the list people open most, and it was the one that dropped the
-- flag: inbox_rooms joins users at both ends of a direct room and took the
-- pseudonym, the seed and the photo, but never is_verified.
SELECT ok(
  (SELECT peer_is_verified FROM public.inbox_rooms
    WHERE room_id = 'aab1aaaa-0000-4000-8000-000000000001'),
  'a verified friend is marked verified in the inbox'
);
SELECT ok(
  NOT (SELECT peer_is_verified FROM public.inbox_rooms
        WHERE room_id = 'aab1aaaa-0000-4000-8000-000000000002'),
  'and somebody who is not, is not'
);

-- The search centre: the screen whose whole job is telling you who somebody
-- is could not tell you the one fact that had been checked.
SELECT ok(
  (SELECT is_verified FROM public.search_global('tickknown', 10)
    WHERE hit_kind = 'user' LIMIT 1),
  'a verified person is marked verified in search'
);
SELECT ok(
  NOT (SELECT is_verified FROM public.search_global('tickplain', 10)
        WHERE hit_kind = 'user' LIMIT 1),
  'and an unverified one is not'
);
-- search_global UNIONs four arms, so the column had to land on all of them.
-- A tribe is not a person; FALSE rather than NULL so the client never has to
-- decide what a null tick means.
SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.search_global('tick', 20)
               WHERE is_verified IS NULL),
  'and nothing in a search result has an undecided tick'
);

-- Mention autocomplete: the list you pick a name out of when you type @.
SELECT ok(
  (SELECT is_verified FROM public.search_tag_candidates('tickknown', 5)
    WHERE kind = 'user' LIMIT 1),
  'a verified person is marked verified when you @ them'
);
SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.search_tag_candidates('tick', 10)
               WHERE kind = 'tribe' AND is_verified),
  'and a tribe never carries a tick'
);

RESET ROLE;

-- The two contracts that gained a column rather than a view.
SELECT has_column('public', 'inbox_rooms', 'peer_is_verified',
  'inbox_rooms exposes the peer tick');
SELECT ok(
  (SELECT count(*)::INT FROM information_schema.routines
    WHERE routine_schema = 'public'
      AND routine_name IN ('search_user_hits', 'search_global',
                           'search_tag_candidates', 'list_whisper_comments')) = 4,
  'and every rewritten function still exists under its own name'
);

SELECT * FROM finish();
ROLLBACK;
