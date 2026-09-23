-- Two provider sign-ins in a row. The second one used to fail outright.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(4);

-- Exactly what Google sends: a name, an email, a picture. No pseudonym,
-- because Google has no idea this app wants one.
INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
VALUES ('bbb50000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','first.google@example.test','', now(),
        '{"provider":"google"}',
        '{"full_name":"A Real Name","picture":"https://example.test/a.png"}',
        now(), now(),'','','','','','','','');

SELECT isnt(
  (SELECT anonymous_pseudonym::TEXT FROM public.users
    WHERE user_id = 'bbb50000-0000-4000-8000-000000000001'),
  NULL,
  'a provider sign-in still gets a profile row'
);

SELECT lives_ok(
  $$ INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                             email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                             created_at, updated_at, confirmation_token, recovery_token,
                             email_change, email_change_token_new,
                             email_change_token_current, phone_change,
                             phone_change_token, reauthentication_token)
     VALUES ('bbb50000-0000-4000-8000-000000000002',
             '00000000-0000-0000-0000-000000000000',
             'authenticated','authenticated','second.google@example.test','', now(),
             '{"provider":"google"}',
             '{"full_name":"Another Name","picture":"https://example.test/b.png"}',
             now(), now(),'','','','','','','','') $$,
  'and so does the second one, which is the whole bug'
);

SELECT isnt(
  (SELECT anonymous_pseudonym::TEXT FROM public.users
    WHERE user_id = 'bbb50000-0000-4000-8000-000000000001'),
  (SELECT anonymous_pseudonym::TEXT FROM public.users
    WHERE user_id = 'bbb50000-0000-4000-8000-000000000002'),
  'they get different handles'
);

-- And the handle is not the person. Google hands over a real name and an
-- email; using either would turn a pseudonymous account into a named one at
-- the moment it is created.
SELECT results_eq(
  $$ SELECT count(*)::INT FROM public.users
      WHERE user_id IN ('bbb50000-0000-4000-8000-000000000001',
                        'bbb50000-0000-4000-8000-000000000002')
        AND (lower(anonymous_pseudonym::TEXT) LIKE '%real%'
          OR lower(anonymous_pseudonym::TEXT) LIKE '%another%'
          OR lower(anonymous_pseudonym::TEXT) LIKE '%google%'
          OR lower(anonymous_pseudonym::TEXT) LIKE '%example%') $$,
  ARRAY[0],
  'the handle is not derived from their name or their email address'
);

SELECT * FROM finish();
ROLLBACK;
