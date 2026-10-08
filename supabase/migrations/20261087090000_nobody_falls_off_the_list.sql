-- Giving back what could not be sent.
--
-- claim_waitlist_digest stamps notified_at and returns the rows in one
-- statement, which is the right shape: two runs overlapping cannot be handed
-- the same addresses. But the stamp happens before the mail is sent, and
-- waitlist-digest had no way to undo it. A Resend outage, an expired key, a
-- 502 on their side -- and those addresses are marked delivered, drop out of
-- every future digest, and exist only in a function log that ages out.
--
-- The people lost that way are exactly the ones who signed up that day.
--
-- The asymmetry decides it. This digest goes to the team, not to members, so
-- reporting an address twice costs somebody three seconds of reading. Losing
-- one costs a person who asked to be told when Venttly opens and then never
-- was. Those are not the same size, so the failure path hands the rows back.
--
-- Bounded to the last hour on purpose. service_role is what every Edge
-- Function runs as, so an unbounded "set notified_at = NULL where email in
-- (...)" would let any one of them resurrect addresses reported months ago.
-- The digest claims and sends within seconds; an hour is slack for a slow
-- Resend call and nothing like enough to reach a delivered list.

CREATE OR REPLACE FUNCTION public.release_waitlist_digest(p_emails TEXT[])
RETURNS BIGINT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    WITH released AS (
        UPDATE public.waitlist_signups
           SET notified_at = NULL
         WHERE notified_at IS NOT NULL
           -- Only a claim this run could plausibly have made.
           AND notified_at > now() - INTERVAL '1 hour'
           -- lower() on both sides, matching waitlist_signups_email_lower_unique
           -- and waitlist_join, so a release cannot miss a row the claim hit.
           AND lower(email) IN (
                 SELECT lower(btrim(e))
                   FROM unnest(COALESCE(p_emails, '{}'::TEXT[])) AS e
               )
        RETURNING 1
    )
    SELECT count(*) FROM released;
$$;

-- Same shape as claim_waitlist_digest: the list is reachable from the digest
-- and from nothing else. anon and authenticated get nothing here either.
REVOKE ALL ON FUNCTION public.release_waitlist_digest(TEXT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.release_waitlist_digest(TEXT[]) TO service_role;

SELECT public.record_migration(
  '20261087090000', 'nobody_falls_off_the_list'
);

NOTIFY pgrst, 'reload schema';
