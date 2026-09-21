-- A switch for the Google button, so it is only offered once it can work.
--
-- The welcome screen offered two alternatives to the anonymous flow, Google and
-- Phone, and both failed at the tap: production auth config has
--
--   external_google_enabled : false
--   external_phone_enabled  : false
--
-- so the first screen a new user ever sees had two buttons out of four that
-- could not complete. Nothing in the client knew that -- the providers are
-- server-side configuration, invisible to the app until the request fails.
--
-- Google is now behind this flag, off, and comes back on the day the OAuth
-- client is configured in Supabase. A flag rather than a code change because
-- the two have to be switched on together and a release is the slower half:
-- turning on external_google_enabled while the button is still hidden is
-- harmless, and turning on the button while the provider is off is not.
--
-- Phone was removed rather than flagged. It needs an SMS provider with
-- per-message billing -- the same gap that already keeps recovery_sms off --
-- and an entry point nobody can finish is worse than one that is not offered.

BEGIN;

INSERT INTO public.feature_flags (flag_key, enabled, description)
VALUES (
  'google_sign_in',
  false,
  'Shows "Continue with Google" on the welcome screen. Leave off until '
  'external_google_enabled is true in the Supabase auth config, or the button '
  'fails at the tap.'
)
ON CONFLICT (flag_key) DO NOTHING;

SELECT public.record_migration(
  '20261035090000', 'google_sign_in_flag'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
