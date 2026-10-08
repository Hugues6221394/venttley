-- Somewhere to put an address, before there is an app to put it in.
--
-- venttly.com is a holding page with a privacy policy on it. People who find
-- it have no way to say "tell me when this opens", which is the only thing
-- the page is for until launch.
--
-- Three decisions worth stating, because each is the privacy-shaped one:
--
-- 1. The table stores an address and a timestamp. No IP, no user agent, no
--    referrer. This is a product that tells people on its own front page that
--    it does not want their real name; collecting a fingerprint to go with a
--    launch notification would be the first thing it did contradicting that.
--
-- 2. anon gets EXECUTE on one function and no rights on the table at all --
--    not SELECT, not INSERT. A direct INSERT grant would let anybody probe
--    the unique constraint to find out whether a given address is on the
--    list, which is a membership oracle for a mailing list about mental
--    health. The function returns void and swallows the conflict, so joining
--    twice is indistinguishable from joining once.
--
-- 3. The digest goes out on a schedule rather than per signup, and it is the
--    only way the list leaves the database. Nothing reads it from the web.

CREATE TABLE IF NOT EXISTS public.waitlist_signups (
    signup_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email       TEXT NOT NULL CHECK (length(email) BETWEEN 3 AND 254),
    -- Where it came from, so a future campaign can be told apart from the
    -- front page. Free text, defaulted, never shown to the person.
    source      TEXT NOT NULL DEFAULT 'site'
                CHECK (length(source) BETWEEN 1 AND 40),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Set when an address has appeared in a digest, so a redelivery or a
    -- missed cron run cannot send the same person twice and cannot skip
    -- somebody either. The digest claims rows by setting this.
    notified_at TIMESTAMPTZ
);

-- Case-insensitive, matching users_pseudonym_lower_unique rather than
-- inventing a second convention. Two people cannot join with Ada@x and ada@x.
CREATE UNIQUE INDEX IF NOT EXISTS waitlist_signups_email_lower_unique
    ON public.waitlist_signups (lower(email));

-- The digest's own query: undelivered rows, oldest first.
CREATE INDEX IF NOT EXISTS waitlist_signups_pending_idx
    ON public.waitlist_signups (created_at)
    WHERE notified_at IS NULL;

ALTER TABLE public.waitlist_signups ENABLE ROW LEVEL SECURITY;

-- No policies, deliberately. RLS with zero policies denies everything to
-- every role that is not BYPASSRLS, which is exactly the intent: the table is
-- reachable through the SECURITY DEFINER function below and through
-- service_role, and by nothing else.
REVOKE ALL ON public.waitlist_signups FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- Joining
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.waitlist_join(p_email TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_email TEXT := lower(btrim(COALESCE(p_email, '')));
BEGIN
    -- Deliberately not a full RFC 5322 parse: the only question worth asking
    -- here is whether this could be an address at all. Anything stricter
    -- rejects real addresses, and anything looser fills the table with junk
    -- that a human has to read in a digest.
    IF v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}$' THEN
        RAISE EXCEPTION 'waitlist_email_invalid'
            USING HINT = 'That does not look like an email address.';
    END IF;

    IF length(v_email) > 254 THEN
        RAISE EXCEPTION 'waitlist_email_invalid'
            USING HINT = 'That address is too long.';
    END IF;

    INSERT INTO public.waitlist_signups (email)
    VALUES (v_email)
    ON CONFLICT (lower(email)) DO NOTHING;

    -- Returns void whether the row was new or already there. Telling the
    -- caller which it was would answer "is this address on the list?" for
    -- anybody who asked, which is the one thing this table must not say.
END;
$$;

REVOKE ALL ON FUNCTION public.waitlist_join(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.waitlist_join(TEXT) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- The digest
-- ---------------------------------------------------------------------------

-- Claims every not-yet-reported signup and returns it, in one statement, so a
-- second caller overlapping the first cannot be handed the same addresses.
-- The caller that receives rows owns delivering them.
CREATE OR REPLACE FUNCTION public.claim_waitlist_digest()
RETURNS TABLE (email TEXT, created_at TIMESTAMPTZ)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    WITH claimed AS (
        UPDATE public.waitlist_signups
           SET notified_at = now()
         WHERE signup_id IN (
               SELECT signup_id
                 FROM public.waitlist_signups
                WHERE notified_at IS NULL
                ORDER BY created_at
                  FOR UPDATE SKIP LOCKED
         )
        RETURNING email, created_at
    )
    SELECT email, created_at FROM claimed ORDER BY created_at;
$$;

REVOKE ALL ON FUNCTION public.claim_waitlist_digest() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_waitlist_digest() TO service_role;

CREATE OR REPLACE FUNCTION public.waitlist_total()
RETURNS BIGINT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT count(*) FROM public.waitlist_signups;
$$;

REVOKE ALL ON FUNCTION public.waitlist_total() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.waitlist_total() TO service_role;

-- ---------------------------------------------------------------------------
-- Schedule
-- ---------------------------------------------------------------------------
--
-- ONE-TIME SETUP, same shape as migration 0076:
--
--   supabase secrets set CRON_SECRET='<SECRET>'     -- if not already set
--   supabase functions deploy waitlist-digest
--
-- The vault secret `account_purge_cron_secret` already holds this value and
-- is reused rather than duplicated -- CRON_SECRET is one shared gate across
-- every internal function, so a second copy would only be a second thing to
-- rotate.

CREATE EXTENSION IF NOT EXISTS pg_net;

-- 06:30 UTC: 08:30 in Kigali, so the list is read with the morning rather
-- than overnight. Idempotent, following 0034 and 0076.
DO $$
DECLARE
    v_existing INT;
BEGIN
    SELECT jobid INTO v_existing
      FROM cron.job
     WHERE jobname = 'waitlist_digest_daily';
    IF v_existing IS NOT NULL THEN
        PERFORM cron.unschedule(v_existing);
    END IF;

    PERFORM cron.schedule(
        'waitlist_digest_daily',
        '30 6 * * *',
        $cron$
        SELECT net.http_post(
            url     := 'https://gyeibgaqrmnepbnfbtzc.functions.supabase.co/waitlist-digest',
            headers := jsonb_build_object(
                'Content-Type',  'application/json',
                'x-cron-secret', (
                    SELECT decrypted_secret
                      FROM vault.decrypted_secrets
                     WHERE name = 'account_purge_cron_secret'
                )
            ),
            body    := '{}'::jsonb
        );
        $cron$
    );
END $$;

SELECT public.record_migration(
  '20261082090000', 'a_waitlist_worth_joining'
);

NOTIFY pgrst, 'reload schema';
