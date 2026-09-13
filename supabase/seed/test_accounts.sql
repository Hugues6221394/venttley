-- ============================================================================
-- Venttly | Test accounts for end-to-end role coverage
--
-- Creates three accounts that span every privilege level used in v1:
--   • tester_user     — plain member
--   • tester_keeper   — keeps a brand-new "Quiet Mornings" Tribe
--   • tester_admin    — super_admin (admin web console access)
--   • tester_verified — plain member carrying a verified badge
--   • tester_keeper2  — keeps TWO Tribes, for multi-tribe Studio coverage
--   • tester_comod    — co-moderator in one of tester_keeper2's Tribes
--
-- The last three exist because the acceptance plan asks for a verified user, a
-- Keeper with multiple Tribes and a co-moderator, and none of them did. The
-- multi-tribe Keeper matters most: a Keeper with exactly one Tribe cannot
-- reveal a Studio that silently assumes there is only ever one.
--
-- Passwords are intentionally weak + shared in chat for dev. Rotate before
-- any external review.
-- ============================================================================

-- 1) Auth rows. The public.users row is materialised automatically by the
--    handle_new_auth_user trigger (migration 0002).
--
--    Idempotent: if the email already exists, we leave the row alone.
INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
)
SELECT
    '00000000-0000-0000-0000-000000000000'::uuid,
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    pseudonym || '@id.venttly.app',
    crypt('TestPass123!', gen_salt('bf')),
    now(),
    jsonb_build_object(
        'pseudonym',   pseudonym,
        'avatar_seed', avatar,
        'birth_year',  1998,
        'safety_tier', 'standard'
    ),
    now(),
    now(),
    '', '', '', ''
FROM (VALUES
    ('tester_user',     'rose-orb-test1'),
    ('tester_keeper',   'plum-orb-test2'),
    ('tester_admin',    'berry-spark-test3'),
    ('tester_verified', 'sage-orb-test4'),
    ('tester_keeper2',  'amber-spark-test5'),
    ('tester_comod',    'slate-orb-test6')
) AS s(pseudonym, avatar)
WHERE NOT EXISTS (
    SELECT 1 FROM auth.users WHERE email = s.pseudonym || '@id.venttly.app'
);

-- 2) Promote tester_admin to super_admin; tester_keeper to plug (Creator Studio).
UPDATE public.users
   SET user_role = 'super_admin'
 WHERE anonymous_pseudonym = 'tester_admin';

UPDATE public.users
   SET user_role = 'plug',
       is_verified = true
 WHERE anonymous_pseudonym = 'tester_keeper';

-- 3) Give tester_keeper a real Tribe to keep, so the manage dashboard is
--    reachable end-to-end. Skipped if they already keep one.
WITH keeper AS (
    SELECT user_id FROM public.users
     WHERE anonymous_pseudonym = 'tester_keeper'
)
INSERT INTO public.tribes
    (name, slug, category, description, is_private, keeper_id)
SELECT
    'Quiet Mornings',
    'quiet-mornings',
    'support',
    'A gentle place for early thoughts. Tea optional. Soft hello required.',
    false,
    keeper.user_id
FROM keeper
WHERE NOT EXISTS (
    SELECT 1 FROM public.tribes
     WHERE keeper_id = keeper.user_id AND slug = 'quiet-mornings'
);

-- Auto-join the keeper to their own tribe (mirrors createTribe in the app).
INSERT INTO public.tribe_members (tribe_id, user_id)
SELECT t.tribe_id, u.user_id
  FROM public.tribes t
  JOIN public.users u ON u.user_id = t.keeper_id
 WHERE u.anonymous_pseudonym = 'tester_keeper'
   AND t.slug = 'quiet-mornings'
ON CONFLICT DO NOTHING;

-- 4) The verified member. Distinct from tester_keeper, which is also verified —
--    a badge that only ever appears on a Keeper cannot show whether the badge
--    or the Keeper role is driving the UI.
UPDATE public.users
   SET is_verified = true
 WHERE anonymous_pseudonym = 'tester_verified';

-- 5) A Keeper with TWO Tribes. This is the account that makes the multi-tribe
--    requirement testable: every Studio KPI, member list and content list must
--    respect the selected Tribe, and one Tribe cannot demonstrate that.
WITH keeper AS (
    SELECT user_id FROM public.users WHERE anonymous_pseudonym = 'tester_keeper2'
)
INSERT INTO public.tribes (name, slug, category, description, is_private, keeper_id)
SELECT v.name, v.slug, 'support', v.descr, false, keeper.user_id
  FROM keeper,
       (VALUES
         ('Late Night Study',  'late-night-study',
          'For the 2am essay crowd. Snacks encouraged, panic optional.'),
         ('Sunday Reset',      'sunday-reset',
          'Tidy the week before it starts. Small wins count.')
       ) AS v(name, slug, descr)
 WHERE NOT EXISTS (
   SELECT 1 FROM public.tribes t WHERE t.slug = v.slug
 );

INSERT INTO public.tribe_members (tribe_id, user_id, role)
SELECT t.tribe_id, u.user_id, 'keeper'
  FROM public.tribes t
  JOIN public.users u ON u.user_id = t.keeper_id
 WHERE u.anonymous_pseudonym = 'tester_keeper2'
   AND t.slug IN ('late-night-study','sunday-reset')
ON CONFLICT DO NOTHING;

-- Unequal membership on purpose: identical counts cannot show a KPI leaking
-- from one Tribe into another's number.
INSERT INTO public.tribe_members (tribe_id, user_id, role)
SELECT t.tribe_id, u.user_id, 'member'
  FROM public.tribes t
  CROSS JOIN public.users u
 WHERE t.slug = 'late-night-study'
   AND u.anonymous_pseudonym IN ('tester_user','tester_verified')
ON CONFLICT DO NOTHING;

-- 6) The co-moderator: elevated inside ONE of tester_keeper2's Tribes and
--    nothing else. Needed to show that moderation powers are scoped to the
--    Tribe that granted them rather than to the person.
INSERT INTO public.tribe_members (tribe_id, user_id, role)
SELECT t.tribe_id, u.user_id, 'mod'
  FROM public.tribes t
  CROSS JOIN public.users u
 WHERE t.slug = 'late-night-study'
   AND u.anonymous_pseudonym = 'tester_comod'
ON CONFLICT (tribe_id, user_id) DO UPDATE SET role = 'mod';

-- 7) Print the resulting accounts so the seed output is self-documenting.
SELECT
    u.anonymous_pseudonym AS username,
    'TestPass123!'        AS password,
    u.user_role           AS role,
    u.safety_tier
FROM public.users u
WHERE u.anonymous_pseudonym IN ('tester_user', 'tester_keeper', 'tester_admin',
                                'tester_verified', 'tester_keeper2', 'tester_comod')
ORDER BY u.anonymous_pseudonym;
