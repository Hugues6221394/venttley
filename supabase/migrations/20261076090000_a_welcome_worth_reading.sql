-- Somebody signs up, and hears from us.
--
-- The dispatcher has carried a `welcome` template since it was written. Not
-- one has ever been sent, because nothing anywhere queues it: queue_email is
-- an RPC the client calls, and no signup screen calls it. The template was
-- real, the sender was configured, and the feature did not exist.
--
-- A trigger rather than a client call, for the same reasons the adopted-signup
-- -email trigger next door is one. Signing up with Google or Apple never
-- touches a Venttly screen that could make the call; confirming an address can
-- happen in a mail client with the app closed; and a client-side send is one
-- dropped request away from a person who joined and heard nothing.
--
-- It fires on the edge where a *real* address first becomes known, which is
-- the only moment there is anywhere to send to:
--
--   provider sign-in — the address arrives confirmed, at INSERT
--   email signup     — confirmed later, at UPDATE
--   anonymous handle — never; there is no inbox, and that is the point
--
-- Once per account, ever. Guarded on the outbox itself rather than a new
-- column: the outbox is the record of what we sent, so asking it "did we"
-- cannot drift from the truth the way a flag can.

CREATE OR REPLACE FUNCTION private.queue_welcome_email()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_name TEXT;
BEGIN
  -- A synthetic handle is not an address. The anonymous flow signs in as
  -- <handle>@id.venttly.app, which nobody can receive mail at — and the
  -- outbox's own CHECK constraint refuses it, so queueing one would turn a
  -- welcome into a failed insert on somebody's signup.
  IF NEW.email IS NULL
     OR NEW.email = ''
     OR NEW.email LIKE '%@id.venttly.app'
     OR NEW.email_confirmed_at IS NULL THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.email_outbox
     WHERE user_id = NEW.id AND template = 'welcome'
  ) THEN
    RETURN NEW;
  END IF;

  -- Named rather than "there". This trigger is ordered after
  -- on_auth_user_created by name, so the profile row exists by now — but the
  -- email is worth sending either way, and the template has its own fallback.
  SELECT COALESCE(u.display_name, u.anonymous_pseudonym)
    INTO v_name
    FROM public.users u
   WHERE u.user_id = NEW.id;

  INSERT INTO public.email_outbox (user_id, template, to_address, variables)
  VALUES (
    NEW.id,
    'welcome',
    NEW.email,
    jsonb_build_object('pseudonym', COALESCE(v_name, 'friend'))
  );

  RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION private.queue_welcome_email()
  FROM PUBLIC, anon, authenticated;

-- Named to sort after on_auth_user_created, because Postgres fires triggers on
-- the same event in name order and the profile row has to exist before the
-- handle can be read off it. 'w' > 'u'; that is the whole mechanism, and it is
-- why this is not called on_auth_email_welcome.
DROP TRIGGER IF EXISTS on_auth_welcome_email ON auth.users;
CREATE TRIGGER on_auth_welcome_email
  AFTER INSERT OR UPDATE OF email_confirmed_at, email ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION private.queue_welcome_email();

-- Deliberately no backfill. Everybody already here would get a "welcome to
-- Venttly" for an account they have been using for weeks, and the seeded
-- community would get 45 of them to addresses that do not exist.

SELECT public.record_migration('20261076090000', 'a_welcome_worth_reading');

NOTIFY pgrst, 'reload schema';
