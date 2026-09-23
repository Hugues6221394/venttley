-- A confirmed signup address becomes the account's recovery email.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(4);

-- Replica throughout the fixture: it suppresses handle_new_user, which would
-- invent colliding pseudonyms, and the users -> auth.users foreign key, which
-- otherwise forces an ordering neither insert can satisfy alone.
SET session_replication_role = replica;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
VALUES ('eee10000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','real.person@example.test','x', NULL,
        '{}','{}', now(), now(),'','','','','','','',''),
       ('eee10000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','emanon@id.venttly.app','x', NULL,
        '{}','{}', now(), now(),'','','','','','','',''),
       ('eee10000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','signup.addr@example.test','x', NULL,
        '{}','{}', now(), now(),'','','','','','','','');

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('eee10000-0000-4000-8000-000000000001','emreal','emreal','x',
        'emreal','emreal','emreal','normal','active',1990),
       ('eee10000-0000-4000-8000-000000000002','emanon','emanon','x',
        'emanon','emanon','emanon','normal','active',1990),
       ('eee10000-0000-4000-8000-000000000003','emchose','emchose','x',
        'emchose','emchose','emchose','normal','active',1990);

-- Somebody who deliberately pointed recovery at a different address.
UPDATE public.users
   SET recovery_email = 'chosen@elsewhere.test', recovery_email_verified = TRUE
 WHERE user_id = 'eee10000-0000-4000-8000-000000000003';

SET session_replication_role = origin;

SELECT is(
  (SELECT recovery_email FROM public.users
    WHERE user_id = 'eee10000-0000-4000-8000-000000000001'),
  NULL,
  'an address that has not been confirmed is not adopted'
);

-- Confirmation, however it arrives.
UPDATE auth.users SET email_confirmed_at = now()
 WHERE id IN ('eee10000-0000-4000-8000-000000000001',
              'eee10000-0000-4000-8000-000000000002',
              'eee10000-0000-4000-8000-000000000003');

SELECT results_eq(
  $$ SELECT recovery_email, recovery_email_verified, email_verified
       FROM public.users
      WHERE user_id = 'eee10000-0000-4000-8000-000000000001' $$,
  $$ VALUES ('real.person@example.test', TRUE, TRUE) $$,
  'confirming a real address adopts it as a verified recovery email'
);

SELECT is(
  (SELECT recovery_email FROM public.users
    WHERE user_id = 'eee10000-0000-4000-8000-000000000002'),
  NULL,
  'a synthetic @id.venttly.app handle is never adopted — nobody can read it'
);

SELECT is(
  (SELECT recovery_email FROM public.users
    WHERE user_id = 'eee10000-0000-4000-8000-000000000003'),
  'chosen@elsewhere.test',
  'an address the user chose themselves outranks the one they signed up with'
);

SELECT * FROM finish();
ROLLBACK;
