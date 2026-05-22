-- ============================================================================
-- Venttly | Test accounts for end-to-end role coverage
--
-- Creates three accounts that span every privilege level used in v1:
--   • tester_user    — plain member
--   • tester_keeper  — keeps a brand-new "Quiet Mornings" Tribe
--   • tester_admin   — super_admin (admin web console access)
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
    ('tester_user',   'rose-orb-test1'),
    ('tester_keeper', 'plum-orb-test2'),
    ('tester_admin',  'berry-spark-test3')
) AS s(pseudonym, avatar)
WHERE NOT EXISTS (
    SELECT 1 FROM auth.users WHERE email = s.pseudonym || '@id.venttly.app'
);

-- 2) Promote tester_admin to super_admin (default role from trigger is 'normal').
UPDATE public.users
   SET user_role = 'super_admin'
 WHERE anonymous_pseudonym = 'tester_admin';

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

-- 4) Print the resulting accounts so the seed output is self-documenting.
SELECT
    u.anonymous_pseudonym AS username,
    'TestPass123!'        AS password,
    u.user_role           AS role,
    u.safety_tier
FROM public.users u
WHERE u.anonymous_pseudonym IN ('tester_user', 'tester_keeper', 'tester_admin')
ORDER BY u.anonymous_pseudonym;
