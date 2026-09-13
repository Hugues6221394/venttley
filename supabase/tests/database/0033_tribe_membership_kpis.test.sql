-- Tribe membership KPIs.
--
-- The original brief was explicit that the "1 member" bug must be fixed at the
-- database, not patched in Flutter, and that the membership lifecycle must be
-- covered by automated tests: creating a membership raises the count, removing
-- lowers it, banning changes it according to policy, joining another tribe
-- moves only that tribe's number, and multiple tribes stay isolated. Those
-- tests did not exist. This is them.
--
-- The membership model, established by reading the schema rather than assuming:
--
--   active   a row in tribe_members (role: member | mod | keeper)
--   pending  a row in tribe_join_requests with status = 'pending'
--   banned   a row in tribe_bans; ban_tribe_member also deletes the membership
--   former   no row anywhere
--
-- tribes.member_count is denormalised, and recompute_tribe_member_count
-- recalculates it from tribe_members on every INSERT, UPDATE and DELETE rather
-- than incrementing a running total. That is the design decision that makes
-- the count untraceably-wrong impossible, so it is pinned here: a
-- +1/-1 counter is exactly what produces a "1 member" bug nobody can explain.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(14);

SET session_replication_role = replica;

INSERT INTO public.users (user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
                          display_name, display_name_normalized, username_normalized,
                          user_role, account_status, birth_year)
VALUES
  ('aaa20000-0000-4000-8000-000000000001','kpikeeper','x','x','kpikeeper','kpikeeper','kpikeeper','normal','active',1990),
  ('aaa20000-0000-4000-8000-000000000002','kpimember1','x','x','kpimember1','kpimember1','kpimember1','normal','active',1995),
  ('aaa20000-0000-4000-8000-000000000003','kpimember2','x','x','kpimember2','kpimember2','kpimember2','normal','active',1995),
  ('aaa20000-0000-4000-8000-000000000004','kpimod','x','x','kpimod','kpimod','kpimod','normal','active',1995),
  ('aaa20000-0000-4000-8000-000000000005','kpipending','x','x','kpipending','kpipending','kpipending','normal','active',1995);

-- Two tribes, because the bug being guarded against is one tribe's membership
-- leaking into another's number.
INSERT INTO public.tribes (tribe_id, name, slug, category, keeper_id)
VALUES
  ('bbb20000-0000-4000-8000-00000000000a','KPI Tribe A','kpi-tribe-a','campus','aaa20000-0000-4000-8000-000000000001'),
  ('bbb20000-0000-4000-8000-00000000000b','KPI Tribe B','kpi-tribe-b','campus','aaa20000-0000-4000-8000-000000000001');

SET session_replication_role = origin;

-- Baseline. Seeded with triggers off, so the counter has not been touched yet.
UPDATE public.tribes SET member_count = 0
 WHERE tribe_id IN ('bbb20000-0000-4000-8000-00000000000a',
                    'bbb20000-0000-4000-8000-00000000000b');

-- ---------------------------------------------------------------------------
-- Creating a membership raises the count
-- ---------------------------------------------------------------------------

INSERT INTO public.tribe_members (tribe_id, user_id, role)
VALUES ('bbb20000-0000-4000-8000-00000000000a','aaa20000-0000-4000-8000-000000000002','member');

SELECT is(
  (SELECT member_count FROM public.tribes WHERE tribe_id='bbb20000-0000-4000-8000-00000000000a'),
  1,
  'joining a Tribe raises its member count to 1'
);

INSERT INTO public.tribe_members (tribe_id, user_id, role)
VALUES ('bbb20000-0000-4000-8000-00000000000a','aaa20000-0000-4000-8000-000000000003','member');

SELECT is(
  (SELECT member_count FROM public.tribes WHERE tribe_id='bbb20000-0000-4000-8000-00000000000a'),
  2,
  'a second member raises it to 2 — the count is not stuck at 1'
);

-- ---------------------------------------------------------------------------
-- Other tribes are unaffected
-- ---------------------------------------------------------------------------

SELECT is(
  (SELECT member_count FROM public.tribes WHERE tribe_id='bbb20000-0000-4000-8000-00000000000b'),
  0,
  'Tribe B is still empty: joining A does not touch B'
);

INSERT INTO public.tribe_members (tribe_id, user_id, role)
VALUES ('bbb20000-0000-4000-8000-00000000000b','aaa20000-0000-4000-8000-000000000002','member');

SELECT results_eq(
  $$ SELECT member_count FROM public.tribes
      WHERE tribe_id IN ('bbb20000-0000-4000-8000-00000000000a',
                         'bbb20000-0000-4000-8000-00000000000b')
      ORDER BY tribe_id $$,
  $$ VALUES (2), (1) $$,
  'one member in two Tribes counts once in each, not twice in either'
);

-- ---------------------------------------------------------------------------
-- Removing lowers it
-- ---------------------------------------------------------------------------

DELETE FROM public.tribe_members
 WHERE tribe_id='bbb20000-0000-4000-8000-00000000000a'
   AND user_id='aaa20000-0000-4000-8000-000000000003';

SELECT is(
  (SELECT member_count FROM public.tribes WHERE tribe_id='bbb20000-0000-4000-8000-00000000000a'),
  1,
  'leaving a Tribe lowers its count'
);

-- ---------------------------------------------------------------------------
-- Banning, through the real path
-- ---------------------------------------------------------------------------

SELECT set_config('request.jwt.claims',
  '{"sub":"aaa20000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);

SELECT lives_ok(
  $$ SELECT public.ban_tribe_member('bbb20000-0000-4000-8000-00000000000a',
                                    'aaa20000-0000-4000-8000-000000000002',
                                    'kpi test') $$,
  'the keeper can ban a member'
);

SELECT is(
  (SELECT member_count FROM public.tribes WHERE tribe_id='bbb20000-0000-4000-8000-00000000000a'),
  0,
  'banning removes the membership, so the count drops — banned members are not active members'
);

SELECT is(
  (SELECT member_count FROM public.tribes WHERE tribe_id='bbb20000-0000-4000-8000-00000000000b'),
  1,
  'and the ban in Tribe A leaves their membership of Tribe B alone'
);

SELECT throws_like(
  $$ INSERT INTO public.tribe_members (tribe_id, user_id, role)
     VALUES ('bbb20000-0000-4000-8000-00000000000a',
             'aaa20000-0000-4000-8000-000000000002','member') $$,
  '%removed from this%',
  'a banned member cannot rejoin and quietly restore the count'
);

-- ---------------------------------------------------------------------------
-- The counter cannot drift
-- ---------------------------------------------------------------------------

-- Corrupt it deliberately, then touch the membership table. A running
-- +1/-1 total would stay wrong forever; recomputing from source heals.
UPDATE public.tribes SET member_count = 999
 WHERE tribe_id='bbb20000-0000-4000-8000-00000000000b';

INSERT INTO public.tribe_members (tribe_id, user_id, role)
VALUES ('bbb20000-0000-4000-8000-00000000000b','aaa20000-0000-4000-8000-000000000004','mod');

SELECT is(
  (SELECT member_count FROM public.tribes WHERE tribe_id='bbb20000-0000-4000-8000-00000000000b'),
  2,
  'a corrupted counter self-heals on the next membership change: it is recomputed from tribe_members, not incremented'
);

SELECT is(
  (SELECT t.member_count FROM public.tribes t WHERE t.tribe_id='bbb20000-0000-4000-8000-00000000000b'),
  (SELECT count(*)::int FROM public.tribe_members WHERE tribe_id='bbb20000-0000-4000-8000-00000000000b'),
  'the stored count equals the real row count — the invariant the "1 member" bug broke'
);

-- ---------------------------------------------------------------------------
-- The KPI surface the Studio actually reads
-- ---------------------------------------------------------------------------

SELECT is(
  (SELECT s.member_count::int FROM public.tribe_studio_stats s
    WHERE s.tribe_id='bbb20000-0000-4000-8000-00000000000b'),
  (SELECT t.member_count::int FROM public.tribes t
    WHERE t.tribe_id='bbb20000-0000-4000-8000-00000000000b'),
  'tribe_studio_stats reports the same number the tribes row holds'
);

SELECT is(
  (SELECT s.moderator_count::int FROM public.tribe_studio_stats s
    WHERE s.tribe_id='bbb20000-0000-4000-8000-00000000000b'),
  1,
  'moderator_count counts mods and keepers, not plain members'
);

-- Pending is a different state, in a different table. A join request must not
-- inflate the member count — that is the distinction the brief asked for.
INSERT INTO public.tribe_join_requests (tribe_id, user_id, status)
VALUES ('bbb20000-0000-4000-8000-00000000000b','aaa20000-0000-4000-8000-000000000005','pending');

SELECT results_eq(
  $$ SELECT member_count::int, pending_requests::int FROM public.tribe_studio_stats
      WHERE tribe_id = 'bbb20000-0000-4000-8000-00000000000b' $$,
  $$ VALUES (2, 1) $$,
  'a pending request counts as pending, never as a member'
);

SELECT * FROM finish();
ROLLBACK;
