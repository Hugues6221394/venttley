-- A verified signup address should be findable in settings.
--
-- Signing up with an email writes auth.users.email and nothing else. The
-- Recovery email page reads public.users.recovery_email, which is only ever
-- written by set_recovery_email — a screen the user never visited, because
-- they already gave an address during signup. So somebody who signed up with
-- their email, confirmed it, and went looking for it in settings found the
-- page empty and their account apparently without any way back in.
--
-- A trigger rather than a client write, for two reasons: confirmation can
-- happen by clicking a link in an email client with the app closed, and the
-- same address arriving from a provider sign-in should land the same way.

CREATE OR REPLACE FUNCTION private.adopt_confirmed_signup_email()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Synthetic handles are not addresses. The anonymous flow signs in as
  -- <something>@id.venttly.app, which nobody can receive mail at, and
  -- offering it as a recovery route would be worse than offering none.
  IF NEW.email IS NULL
     OR NEW.email = ''
     OR NEW.email LIKE '%@id.venttly.app' THEN
    RETURN NEW;
  END IF;

  IF NEW.email_confirmed_at IS NULL THEN
    RETURN NEW;
  END IF;

  UPDATE public.users u
     SET recovery_email          = NEW.email,
         recovery_email_verified = TRUE,
         recovery_email_added_at = COALESCE(u.recovery_email_added_at, now()),
         recovery_email_pending  = NULL,
         email_verified          = TRUE
   WHERE u.user_id = NEW.id
     -- Never overwrite a different address the user chose deliberately. They
     -- may well want password resets going somewhere other than the address
     -- they signed up with, and that decision outranks this convenience.
     AND (u.recovery_email IS NULL OR u.recovery_email = NEW.email);

  RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION private.adopt_confirmed_signup_email()
  FROM PUBLIC, anon, authenticated;

-- Both edges: confirmed at creation (an admin invite, a provider sign-in) and
-- confirmed later (the ordinary case, where the code arrives by mail).
DROP TRIGGER IF EXISTS on_auth_email_confirmed ON auth.users;
CREATE TRIGGER on_auth_email_confirmed
  AFTER INSERT OR UPDATE OF email_confirmed_at, email ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION private.adopt_confirmed_signup_email();

-- Backfill: every account already in this state, which is all of them, since
-- nothing has ever written recovery_email for a signup address.
UPDATE public.users u
   SET recovery_email          = a.email,
       recovery_email_verified = TRUE,
       recovery_email_added_at = COALESCE(u.recovery_email_added_at, a.email_confirmed_at, now()),
       email_verified          = TRUE
  FROM auth.users a
 WHERE a.id = u.user_id
   AND a.email IS NOT NULL
   AND a.email <> ''
   AND a.email NOT LIKE '%@id.venttly.app'
   AND a.email_confirmed_at IS NOT NULL
   AND u.recovery_email IS NULL;

SELECT public.record_migration(
  '20261039090000', 'signup_email_is_the_recovery_email'
);

NOTIFY pgrst, 'reload schema';
