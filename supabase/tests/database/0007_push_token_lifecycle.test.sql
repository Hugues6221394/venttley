BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(19);

SELECT ok(
  has_function_privilege(
    'authenticated', 'public.unregister_push_token(text)', 'EXECUTE'
  ),
  'authenticated users can unregister one installation token'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.unregister_push_token(text)', 'EXECUTE'
  ),
  'anonymous callers cannot unregister an installation token'
);
SELECT ok(
  has_function_privilege(
    'authenticated', 'public.unregister_all_push_tokens()', 'EXECUTE'
  ),
  'authenticated users can remove all of their installation tokens'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.unregister_all_push_tokens()', 'EXECUTE'
  ),
  'anonymous callers cannot remove push tokens'
);
SELECT is(
  (
    SELECT procedure.prosecdef
      FROM pg_catalog.pg_proc AS procedure
     WHERE procedure.oid =
       'public.unregister_push_token(text)'::REGPROCEDURE
  ),
  TRUE,
  'single-token teardown has the intended security-definer context'
);
SELECT is(
  (
    SELECT procedure.proconfig @> ARRAY['search_path=""']::TEXT[]
      FROM pg_catalog.pg_proc AS procedure
     WHERE procedure.oid =
       'public.unregister_push_token(text)'::REGPROCEDURE
  ),
  TRUE,
  'single-token teardown has an empty search path'
);
SELECT is(
  (
    SELECT procedure.proconfig @> ARRAY['search_path=""']::TEXT[]
      FROM pg_catalog.pg_proc AS procedure
     WHERE procedure.oid =
       'public.unregister_all_push_tokens()'::REGPROCEDURE
  ),
  TRUE,
  'all-token teardown has an empty search path'
);

INSERT INTO auth.users (
  id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) VALUES
  (
    '93000000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'push-owner-a@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"push_owner_a","avatar_seed":"push-owner-a","birth_year":2000}'::JSONB,
    now(), now()
  ),
  (
    '93000000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'push-owner-b@id.venttly.app',
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"pseudonym":"push_owner_b","avatar_seed":"push-owner-b","birth_year":2000}'::JSONB,
    now(), now()
  );

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '93000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"93000000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT lives_ok(
  $$SELECT public.register_push_token(
    'push-owner-a-device-0001', 'android', 'en-RW', '1.0.0'
  )$$,
  'first owner can register device one'
);
SELECT lives_ok(
  $$SELECT public.register_push_token(
    'push-owner-a-device-0002', 'ios', 'en-RW', '1.0.0'
  )$$,
  'first owner can register device two'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '93000000-0000-4000-8000-000000000002';
SET LOCAL "request.jwt.claims" =
  '{"sub":"93000000-0000-4000-8000-000000000002","role":"authenticated"}';
SELECT lives_ok(
  $$SELECT public.register_push_token(
    'push-owner-b-device-0001', 'android', 'en-RW', '1.0.0'
  )$$,
  'second owner can register a device'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = '93000000-0000-4000-8000-000000000001';
SET LOCAL "request.jwt.claims" =
  '{"sub":"93000000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT lives_ok(
  $$SELECT public.unregister_push_token('push-owner-b-device-0001')$$,
  'owner-scoped single-token teardown is a harmless no-op for another owner'
);
SELECT is(
  public.unregister_all_push_tokens(),
  2,
  'global sign-out removes every token owned by the caller'
);

RESET ROLE;
SELECT is(
  (
    SELECT count(*)::INT
      FROM public.push_tokens
     WHERE user_id = '93000000-0000-4000-8000-000000000002'
  ),
  1,
  'global sign-out does not remove another account token'
);
SELECT is(
  (
    SELECT count(*)::INT
      FROM public.push_tokens
     WHERE user_id = '93000000-0000-4000-8000-000000000001'
  ),
  0,
  'the caller has no remaining push token rows'
);

SET LOCAL ROLE authenticated;
SELECT throws_ok(
  $$SELECT public.register_push_token(
    'invalid token with spaces', 'android', 'en-RW', '1.0.0'
  )$$,
  'P0001',
  'invalid_push_token',
  'server rejects whitespace-bearing fake tokens'
);
SELECT lives_ok(
  $$
    DO $cap$
    BEGIN
      FOR i IN 1..12 LOOP
        PERFORM public.register_push_token(
          format('push-cap-token-%s-0000', i),
          'android', 'en-RW', '1.0.0'
        );
      END LOOP;
    END
    $cap$
  $$,
  'bounded legitimate installation registrations succeed'
);
RESET ROLE;
SELECT is(
  (
    SELECT count(*)::INT
      FROM public.push_tokens
     WHERE user_id = '93000000-0000-4000-8000-000000000001'
  ),
  10,
  'one hostile account cannot retain more than ten installation tokens'
);

SET LOCAL ROLE authenticated;
SELECT lives_ok(
  $$
    DO $quota$
    BEGIN
      FOR i IN 13..18 LOOP
        PERFORM public.register_push_token(
          format('push-cap-token-%s-0000', i),
          'android', 'en-RW', '1.0.0'
        );
      END LOOP;
    END
    $quota$
  $$,
  'registration quota permits the documented twenty calls per minute'
);
SELECT throws_ok(
  $$SELECT public.register_push_token(
    'push-cap-token-19-0000', 'android', 'en-RW', '1.0.0'
  )$$,
  'P0001',
  'rate_limited',
  'registration call twenty-one is rejected server-side'
);
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
