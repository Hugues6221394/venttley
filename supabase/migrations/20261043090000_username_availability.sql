-- Tell somebody their username is taken while they are typing it, not after
-- they have filled in the rest of the form.
--
-- Until now the only answer came from the insert failing, which meant picking
-- a password, agreeing to two policies and pressing the button before finding
-- out the name was gone.
--
-- Callable by anon, because signup has no session. That makes it a username
-- enumeration surface, which is worth stating plainly: it is not much of one.
-- Handles are printed next to every vent, every whisper and every comment in
-- the app, so anybody who wants the list can read the feed. What this adds is
-- a cheaper way to ask, which is why it is a single index-backed lookup that
-- returns one boolean and nothing else — no row, no id, no "did you mean".
--
-- It is advice, not enforcement. Uniqueness is guaranteed by
-- users_pseudonym_lower_unique, and two people racing for the last free name
-- still ends with one insert failing. This only means it usually will not
-- happen, and that when it does the message is not a surprise.

CREATE OR REPLACE FUNCTION public.username_available(p_username TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    -- Shape first. A handle that cannot be saved is not "available", and
    -- answering true for one would put a tick beside something the insert is
    -- about to reject.
    p_username IS NOT NULL
    AND pg_catalog.btrim(p_username) ~ '^[A-Za-z0-9_]{3,24}$'
    AND NOT EXISTS (
      -- lower(), matching users_pseudonym_lower_unique exactly. Anything else
      -- and the tick disagrees with the index that has the final say.
      SELECT 1 FROM public.users u
       WHERE pg_catalog.lower(u.anonymous_pseudonym) =
             pg_catalog.lower(pg_catalog.btrim(p_username))
    );
$$;

REVOKE ALL ON FUNCTION public.username_available(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.username_available(TEXT) TO anon, authenticated;

SELECT public.record_migration(
  '20261043090000', 'username_availability'
);

NOTIFY pgrst, 'reload schema';
