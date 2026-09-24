-- A keeper finds out what happened in their tribe.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(10);

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
    ('dde10000-0000-4000-8000-000000000001'::UUID),  -- the keeper
    ('dde10000-0000-4000-8000-000000000002'::UUID),  -- joins, and is reported on
    ('dde10000-0000-4000-8000-000000000003'::UUID)   -- reports
  ) AS v(id);

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year, created_at)
VALUES
  ('dde10000-0000-4000-8000-000000000001','toldkeeper','x','x','Keeper','keeper','toldkeeper','normal','active',1990, now() - INTERVAL '2 years'),
  ('dde10000-0000-4000-8000-000000000002','toldjoiner','x','x','Joiner','joiner','toldjoiner','normal','active',1990, now() - INTERVAL '2 years'),
  ('dde10000-0000-4000-8000-000000000003','toldreporter','x','x','Reporter','reporter','toldreporter','normal','active',1990, now() - INTERVAL '2 years');

INSERT INTO public.tribes (tribe_id, name, slug, keeper_id, category, visibility)
VALUES ('dde1aaaa-0000-4000-8000-000000000001','Open Tribe','told-open',
        'dde10000-0000-4000-8000-000000000001','campus','public'),
       ('dde1aaaa-0000-4000-8000-000000000002','Shut Tribe','told-shut',
        'dde10000-0000-4000-8000-000000000001','campus','private');

INSERT INTO public.posts (post_id, author_id, tribe_id, content, category_name, post_mood)
VALUES ('dde1bbbb-0000-4000-8000-000000000001',
        'dde10000-0000-4000-8000-000000000002',
        'dde1aaaa-0000-4000-8000-000000000001',
        'something somebody objected to','mental_health','hopeful');

INSERT INTO public.policy_acceptances (user_id, kind, version)
SELECT u.user_id, c.kind, c.version
  FROM public.users u, public.current_policies() c
ON CONFLICT DO NOTHING;

SET session_replication_role = origin;

-- Somebody joins a public tribe.
INSERT INTO public.tribe_members (tribe_id, user_id, role)
VALUES ('dde1aaaa-0000-4000-8000-000000000001',
        'dde10000-0000-4000-8000-000000000002','member');

SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = 'dde10000-0000-4000-8000-000000000001'
      AND kind = 'tribe_member_joined'),
  1,
  'the keeper is told when somebody joins a public tribe'
);

-- The same in a private tribe is silence, because the keeper approved it a
-- moment earlier and being told what you just did is how a list stops being
-- read.
INSERT INTO public.tribe_members (tribe_id, user_id, role)
VALUES ('dde1aaaa-0000-4000-8000-000000000002',
        'dde10000-0000-4000-8000-000000000002','member');

SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = 'dde10000-0000-4000-8000-000000000001'
      AND kind = 'tribe_member_joined'),
  1,
  'and not told again when they approved it themselves'
);

-- The keeper's own membership row, written when a tribe is created.
INSERT INTO public.tribe_members (tribe_id, user_id, role)
VALUES ('dde1aaaa-0000-4000-8000-000000000001',
        'dde10000-0000-4000-8000-000000000001','keeper');
SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = 'dde10000-0000-4000-8000-000000000001'
      AND kind = 'tribe_member_joined'),
  1,
  'nor when the keeper is the one joining'
);

-- A report. This is the one with a clock on it.
INSERT INTO public.reports (post_id, reporter_id, reason)
VALUES ('dde1bbbb-0000-4000-8000-000000000001',
        'dde10000-0000-4000-8000-000000000003','harassment');

SELECT is(
  (SELECT count(*)::INT FROM public.notifications
    WHERE user_id = 'dde10000-0000-4000-8000-000000000001'
      AND kind = 'tribe_report_filed'),
  1,
  'the keeper is told when a vent in their tribe is reported'
);
-- Who reported it is not the keeper's business, and an actor_id would put it
-- one join away from them.
SELECT is(
  (SELECT actor_id FROM public.notifications
    WHERE user_id = 'dde10000-0000-4000-8000-000000000001'
      AND kind = 'tribe_report_filed'),
  NULL,
  'without naming who reported it'
);
SELECT is(
  (SELECT payload->>'tribe_slug' FROM public.notifications
    WHERE user_id = 'dde10000-0000-4000-8000-000000000001'
      AND kind = 'tribe_report_filed'),
  'told-open',
  'and carrying the tribe the tap target needs'
);

-- The centre.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"dde10000-0000-4000-8000-000000000001","role":"authenticated"}';

SELECT ok(
  (SELECT count(*) FROM public.keeper_tribe_notifications(30)) >= 2,
  'the keeper centre lists them'
);
SELECT ok(
  public.keeper_unread_notification_count() >= 2,
  'and the badge counts them'
);

-- Reading is what clears it, rather than a separate gesture nobody performs.
SELECT ok(
  public.mark_keeper_notifications_read() >= 2,
  'opening the centre marks them read'
);
SELECT is(
  public.keeper_unread_notification_count(),
  0,
  'and the badge goes away'
);

SELECT * FROM finish();
ROLLBACK;
