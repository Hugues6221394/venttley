-- Give the seeded accounts the identity row a real account has.
--
-- Every account this repository seeds is created by INSERT INTO auth.users —
-- supabase/seed/test_accounts.sql for the team's logins, scripts/seed/load.py
-- for the starting community. That writes the user and nothing in
-- auth.identities, which is the table GoTrue keeps one row in per sign-in
-- method. On production 53 of 57 accounts had none; the four that did were the
-- ones made through the app's own signup.
--
-- To be clear about what this does NOT fix: password sign-in works without it.
-- That was measured, not assumed — the local stack had zero identity rows and
-- signed in fine. It was a tempting explanation for a production login that
-- would not work and it was the wrong one.
--
-- What it does fix is everything that reads identities rather than users:
-- listing a person's sign-in methods, and linking a provider to an account that
-- already exists. That last one matters now, because Continue with Google and
-- Continue with Apple land next — somebody who signs in with Google using the
-- same address as a seeded account needs an identity to link to, and without
-- one the outcomes are a duplicate account or a refusal.
--
-- Touches no password. Idempotent: an account that already has an email
-- identity is left alone.
--
--   psql "$DB" -f scripts/seed/repair_auth_identities.sql

-- GoTrue reads the provider list off the user as well as the identity, and a
-- hand-inserted row has an empty raw_app_meta_data.
UPDATE auth.users
   SET raw_app_meta_data =
         COALESCE(raw_app_meta_data, '{}'::jsonb)
         || '{"provider":"email","providers":["email"]}'::jsonb
 WHERE email IS NOT NULL
   AND COALESCE(raw_app_meta_data ->> 'provider', '') = '';

-- Not `email`: on current GoTrue that column is GENERATED from
-- identity_data ->> 'email', and naming it in the insert is an error.
INSERT INTO auth.identities (
  id, user_id, provider_id, provider, identity_data,
  last_sign_in_at, created_at, updated_at
)
SELECT
  gen_random_uuid(),
  a.id,
  -- For the email provider GoTrue uses the user's own id as provider_id.
  a.id::TEXT,
  'email',
  jsonb_build_object(
    'sub', a.id::TEXT,
    'email', a.email,
    'email_verified', a.email_confirmed_at IS NOT NULL,
    'phone_verified', false
  ),
  NULL,
  a.created_at,
  a.updated_at
FROM auth.users a
LEFT JOIN auth.identities i
       ON i.user_id = a.id AND i.provider = 'email'
WHERE a.email IS NOT NULL
  AND i.id IS NULL;

SELECT 'accounts: ' || count(*)
       || '   able to sign in: ' || count(i.id) AS result
FROM auth.users a
LEFT JOIN auth.identities i ON i.user_id = a.id;
