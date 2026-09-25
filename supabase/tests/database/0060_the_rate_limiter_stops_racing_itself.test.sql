-- The rate limiter, which used to fail when two requests arrived together.
--
-- The race itself cannot be reproduced in pgTAP — one session, one
-- transaction, nothing to race against. It was found with pgbench: twenty-five
-- concurrent clients calling search, every one of them dying with
-- "duplicate key value violates unique constraint rate_limits_pkey", and after
-- the fix thirty clients hammering the same fresh key for ten seconds with
-- zero failures.
--
-- What is testable here is the shape that made it racy, and the behaviour that
-- had to survive the rewrite.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(9);

SET session_replication_role = replica;

INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, confirmation_token, recovery_token,
                        email_change, email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
VALUES ('eef10000-0000-4000-8000-000000000001',
        '00000000-0000-0000-0000-000000000000','authenticated','authenticated',
        'ratelimit@id.venttly.app','x', now(),'{}','{}',
        now() - INTERVAL '2 years', now(),'','','','','','','','');

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES ('eef10000-0000-4000-8000-000000000001','ratelimiter','x','x',
        'Rate','rate','ratelimiter','normal','active',1990);

SET session_replication_role = origin;

-- The shape. FOR UPDATE cannot lock a row that does not exist, so a
-- read-then-insert has a window between them where a second session finds
-- nothing too. ON CONFLICT closes it because the database does both halves in
-- one statement.
SELECT ok(
  pg_get_functiondef('public.claim_rate_limit(text,integer,integer)'::regprocedure)
    LIKE '%ON CONFLICT%',
  'the claim is a single upsert'
);
SELECT ok(
  pg_get_functiondef('public.claim_rate_limit(text,integer,integer)'::regprocedure)
    NOT LIKE '%FOR UPDATE%',
  'and not a read-then-insert with a lock that cannot be taken'
);

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"eef10000-0000-4000-8000-000000000001","role":"authenticated"}';

-- The first call is the one that used to race, and it still has to work.
SELECT ok(
  public.claim_rate_limit('pgtap_first', 3600, 3),
  'the first claim on a fresh key is allowed'
);
SELECT ok(
  public.claim_rate_limit('pgtap_first', 3600, 3),
  'and the second, which is the path that always worked'
);
SELECT ok(
  public.claim_rate_limit('pgtap_first', 3600, 3),
  'and the third, which reaches the limit exactly'
);
SELECT ok(
  NOT public.claim_rate_limit('pgtap_first', 3600, 3),
  'the fourth is refused'
);
SELECT ok(
  NOT public.claim_rate_limit('pgtap_first', 3600, 3),
  'and stays refused rather than letting one through'
);

-- The window turns over on time, not on the count. The rewrite lets the
-- counter keep climbing past the maximum where the old one pinned it there;
-- neither is visible to a caller, but the reset has to still happen.
RESET ROLE;
UPDATE public.rate_limits
   SET window_started_at = now() - INTERVAL '2 hours'
 WHERE user_id = 'eef10000-0000-4000-8000-000000000001'
   AND action_key = 'pgtap_first';

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"eef10000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT ok(
  public.claim_rate_limit('pgtap_first', 3600, 3),
  'an expired window starts again'
);
RESET ROLE;
-- Read as postgres: rate_limits is revoked from authenticated on purpose, so
-- only the definer function may touch it.
SELECT is(
  (SELECT counter FROM public.rate_limits
    WHERE user_id = 'eef10000-0000-4000-8000-000000000001'
      AND action_key = 'pgtap_first'),
  1,
  'counting from one, not from where it left off'
);

SELECT * FROM finish();
ROLLBACK;
