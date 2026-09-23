-- Is this username free, asked before the form is submitted.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(7);

SET session_replication_role = replica;
INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
VALUES ('aaa90000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','taken@id.venttly.app','x', now(),
        '{}','{}', now(), now(),'','','','','','','','');
INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('aaa90000-0000-4000-8000-000000000001','TakenName','x','x',
        'TakenName','takenname','takenname','normal','active',1990);
SET session_replication_role = origin;

SET LOCAL ROLE anon;

SELECT ok(
  public.username_available('a_completely_free_one'),
  'a free handle is available, and anon can ask'
);

SELECT ok(
  NOT public.username_available('TakenName'),
  'a handle in use is not available'
);

-- The unique index is on lower(), so the answer has to be too. If these
-- disagreed, the tick would say yes and the insert would say no.
SELECT ok(
  NOT public.username_available('takenname'),
  'case does not make it free'
);
SELECT ok(
  NOT public.username_available('TAKENNAME'),
  'nor does shouting it'
);

-- A handle that cannot be saved is not "available". Answering true here would
-- put a tick beside something guard_user_identity is about to reject.
SELECT ok(
  NOT public.username_available('ab'),
  'too short is not available'
);
SELECT ok(
  NOT public.username_available('has spaces'),
  'invalid characters are not available'
);
SELECT ok(
  NOT public.username_available(NULL),
  'and neither is nothing at all'
);

SELECT * FROM finish();
ROLLBACK;
