-- A ranking change is easy to ship and hard to notice going wrong. The
-- failures are quiet: the same twenty posts every morning, most of what gets
-- written never shown to anybody, one loud account holding the country's
-- first page. None of it raises an error, so somebody has to be able to look.
--
-- The numbers are only worth having if they are not readable by the people
-- being measured, so the first assertion here is the refusal.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(6);

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
    ('fee30000-0000-4000-8000-000000000001'::UUID),  -- an ordinary member
    ('fee30000-0000-4000-8000-000000000002'::UUID),  -- a super admin
    ('fee30000-0000-4000-8000-000000000003'::UUID)   -- writes the post
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, created_at)
VALUES
  ('fee30000-0000-4000-8000-000000000001','fh_member','x','x','M','m','fh_member','normal','active',1990, now() - INTERVAL '2 years'),
  ('fee30000-0000-4000-8000-000000000002','fh_admin','x','x','A','a','fh_admin','super_admin','active',1990, now() - INTERVAL '2 years'),
  ('fee30000-0000-4000-8000-000000000003','fh_writer','x','x','W','w','fh_writer','normal','active',1990, now() - INTERVAL '2 years');

INSERT INTO public.posts (post_id, author_id, category_name, content, post_mood, created_at)
VALUES ('fee3bbbb-0000-4000-8000-000000000001','fee30000-0000-4000-8000-000000000003',
        'mental_health','something somebody read','angry', now() - INTERVAL '2 hours');

INSERT INTO public.post_impressions (user_id, post_id, seen_at, seen_count)
VALUES ('fee30000-0000-4000-8000-000000000001',
        'fee3bbbb-0000-4000-8000-000000000001', now() - INTERVAL '5 minutes', 2);

SET session_replication_role = origin;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"fee30000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT throws_ok(
  $$SELECT public.admin_feed_health()$$,
  '42501',
  NULL,
  'an ordinary member cannot read how the feed is behaving for everyone'
);

SET LOCAL request.jwt.claims = '{"sub":"fee30000-0000-4000-8000-000000000002","role":"authenticated"}';

SELECT ok(
  (public.admin_feed_health() ? 'coverage_pct'),
  'a super admin can'
);

SELECT ok(
  (public.admin_feed_health() ->> 'posts_shown')::BIGINT >= 1,
  'and the count of what was shown includes the impression above'
);

SELECT ok(
  (public.admin_feed_health() ->> 'repeat_share_pct')::FLOAT > 0,
  'a post read twice shows up as repetition, which is the number that says '
  'the feed is going stale'
);

SELECT ok(
  (public.admin_feed_health() ->> 'coverage_pct')::FLOAT > 0,
  'and coverage says how much of what people wrote reached anybody at all'
);

SELECT ok(
  jsonb_array_length(public.admin_feed_health() -> 'loudest_authors') >= 1,
  'with the accounts holding the largest share of everyone''s feed named'
);

SELECT * FROM finish();
ROLLBACK;
