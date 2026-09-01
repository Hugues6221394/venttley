-- Let the outbox mail an address the account does not yet own.
--
-- email-dispatcher resolves the recipient from auth.users.email and skips the
-- row outright when that ends in @id.venttly.app:
--
--     if (!to || to.endsWith("@id.venttly.app"))
--       complete(..., "skipped", "no_real_email")
--
-- Every anonymous account has exactly such an address, so no transactional
-- email has ever reached one. Not the welcome mail, not password reset, and not
-- the security alerts the safety brief requires. The email channel has been
-- switched off for the core user since it was built, silently, one row at a
-- time marked "skipped".
--
-- It also makes verifying a recovery address impossible by construction: the
-- whole point is to mail an address the account does NOT yet have, and prove
-- the person reading it is the person asking.
--
-- So a row may now name its own recipient. When to_address is set the
-- dispatcher uses it and does not consult auth at all; when it is null nothing
-- changes and the old path applies.
--
-- WHY THIS IS SAFE TO ADD
--
-- email_outbox has RLS on and grants clients SELECT only — there is no INSERT
-- privilege for authenticated or anon. Rows can only be queued by SECURITY
-- DEFINER functions and the service role, so "the client can choose where mail
-- goes" is not reachable. The constraints below are the second line: a shape
-- check, and a refusal to ever send to the synthetic domain, which would mean a
-- caller had confused an internal identifier for a mailbox.

BEGIN;

ALTER TABLE public.email_outbox
  ADD COLUMN IF NOT EXISTS to_address TEXT;

COMMENT ON COLUMN public.email_outbox.to_address IS
  'Explicit recipient. NULL means use the account email. Set only by SECURITY DEFINER callers — clients have no INSERT privilege here.';

ALTER TABLE public.email_outbox
  DROP CONSTRAINT IF EXISTS email_outbox_to_address_shape;
ALTER TABLE public.email_outbox
  ADD CONSTRAINT email_outbox_to_address_shape CHECK (
    to_address IS NULL
    OR (
      -- Deliberately loose. This is a sanity check against a caller passing a
      -- username or a UUID, not an attempt to validate email addresses in a
      -- regular expression — that is a losing game, and Resend will reject
      -- what it cannot deliver.
      to_address ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
      AND length(to_address) BETWEEN 6 AND 320
      -- The synthetic login domain is not a mailbox. A row addressed there
      -- means something upstream mistook an internal identifier for a real
      -- address, and it must fail loudly rather than queue mail into a void.
      AND to_address NOT LIKE '%@id.venttly.app'
    )
  );

-- ---------------------------------------------------------------------------
-- The claim function has to hand the new column to the dispatcher
-- ---------------------------------------------------------------------------
--
-- Adding a column to RETURNS TABLE changes the return type, which
-- CREATE OR REPLACE refuses with 42P13. So: drop, recreate, and re-grant —
-- dropping a function takes its privileges with it, and forgetting that would
-- leave the cron job unable to call it.
--
-- This matters more than it looks. If the function did not return to_address,
-- the dispatcher would read undefined, fall back to the account email, and
-- quietly send a recovery-verification link to the synthetic address — where it
-- would be skipped as no_real_email. The feature would appear to work and
-- deliver nothing. Same silent-column shape that has bitten this project
-- repeatedly, and the reason media_status is now in the row-shape guard.
--
-- Body is otherwise identical to 20260811222118: same lease, same exhaustion
-- sweep, same ordering, same SKIP LOCKED.

DROP FUNCTION IF EXISTS public.claim_email_deliveries(INT);

CREATE FUNCTION public.claim_email_deliveries(p_batch INT DEFAULT 25)
RETURNS TABLE (
  outbox_id UUID,
  user_id UUID,
  template TEXT,
  variables JSONB,
  attempts INT,
  to_address TEXT
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH exhausted AS (
    UPDATE public.email_outbox AS outbox
       SET status = 'failed',
           lease_expires_at = NULL,
           last_error = COALESCE(outbox.last_error, 'lease_exhausted')
     WHERE outbox.status = 'sending'
       AND outbox.attempts >= 8
       AND outbox.lease_expires_at < now()
    RETURNING outbox.outbox_id
  ), candidates AS (
    SELECT outbox.outbox_id
      FROM public.email_outbox AS outbox
     WHERE outbox.attempts < 8
       AND outbox.available_at <= now()
       AND (
         outbox.status = 'queued'
         OR (outbox.status = 'sending' AND outbox.lease_expires_at < now())
       )
     ORDER BY outbox.available_at, outbox.created_at
     FOR UPDATE SKIP LOCKED
     LIMIT LEAST(GREATEST(COALESCE(p_batch, 25), 1), 100)
  )
  UPDATE public.email_outbox AS outbox
     SET status = 'sending',
         attempts = outbox.attempts + 1,
         lease_expires_at = now() + INTERVAL '2 minutes'
    FROM candidates
   WHERE outbox.outbox_id = candidates.outbox_id
  RETURNING outbox.outbox_id, outbox.user_id, outbox.template,
            outbox.variables, outbox.attempts, outbox.to_address;
$$;

REVOKE ALL ON FUNCTION public.claim_email_deliveries(INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_email_deliveries(INT) TO service_role;

COMMIT;

SELECT public.record_migration(
  '20260909090000', 'outbox_explicit_recipient'
);

NOTIFY pgrst, 'reload schema';
