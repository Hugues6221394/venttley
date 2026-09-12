-- A skipped message with an explicit recipient is a misconfiguration, not a
-- verdict about the user.
--
-- Found while testing the recovery flow end to end. The verification email was
-- queued correctly with to_address = docworld74@gmail.com, and the dispatcher
-- answered:
--
--     {"claimed":1,"sent":0,"skipped":1}   last_error: no_real_email
--
-- The cause was that the fixed dispatcher had not been deployed yet, so the old
-- code still resolved the recipient from auth.users.email and skipped the
-- synthetic address. Fine — that was a deploy step. What is not fine is what
-- happened to the row.
--
-- claim_email_deliveries only picks up rows that are 'queued', or 'sending'
-- with an expired lease. 'skipped' is terminal. So the message was dropped
-- permanently, and the person waiting for a code would have waited forever with
-- nothing anywhere telling them why. No error in the app, no retry, no alert —
-- the exact silent failure the pre-launch review is looking for.
--
-- The distinction that matters: 'no_real_email' is a legitimate, permanent
-- outcome for a row with NO to_address — that account genuinely has nowhere to
-- receive mail, and retrying forever would be pointless. But when to_address is
-- set, the address is right there. Skipping it can only mean the dispatcher was
-- misconfigured or stale, and that is a transient condition worth retrying.
--
-- So: addressed mail that was skipped for no_real_email goes back to 'queued'
-- with its attempts reset, and the next drain sends it. Unaddressed mail is
-- untouched.

BEGIN;

-- Recover anything already stranded, including the row from the test above.
UPDATE public.email_outbox
   SET status = 'queued',
       attempts = 0,
       last_error = NULL,
       lease_expires_at = NULL
 WHERE status = 'skipped'
   AND last_error = 'no_real_email'
   AND to_address IS NOT NULL;

-- And stop it happening again. A skip is only allowed to be terminal when
-- there was no address to try.
CREATE OR REPLACE FUNCTION public.requeue_addressed_skips(p_limit INT DEFAULT 500)
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_count INT;
BEGIN
  WITH stranded AS (
    SELECT outbox_id
      FROM public.email_outbox
     WHERE status = 'skipped'
       AND last_error = 'no_real_email'
       AND to_address IS NOT NULL
     ORDER BY created_at
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 500), 1), 5000)
  )
  UPDATE public.email_outbox AS outbox
     SET status = 'queued',
         attempts = 0,
         last_error = NULL,
         lease_expires_at = NULL
    FROM stranded
   WHERE outbox.outbox_id = stranded.outbox_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

COMMENT ON FUNCTION public.requeue_addressed_skips(INT) IS
  'Return mail skipped as no_real_email despite having an explicit recipient to the queue. Such a skip means a stale or misconfigured dispatcher, not a user without an address.';

REVOKE ALL ON FUNCTION public.requeue_addressed_skips(INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.requeue_addressed_skips(INT) TO service_role;

-- Every minute, just after the drain job from 0077. Cheap: the WHERE matches
-- nothing in normal operation, and when it does match, somebody is waiting for
-- a verification code.
DO $$
DECLARE v_existing INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE NOTICE 'pg_cron not installed; skipping schedule';
    RETURN;
  END IF;

  SELECT jobid INTO v_existing FROM cron.job
   WHERE jobname = 'requeue_addressed_email_skips';
  IF v_existing IS NOT NULL THEN
    PERFORM cron.unschedule(v_existing);
  END IF;

  PERFORM cron.schedule(
    'requeue_addressed_email_skips',
    '* * * * *',
    $cron$ SELECT public.requeue_addressed_skips(500); $cron$
  );
END $$;

COMMIT;

SELECT public.record_migration(
  '20260911090000', 'requeue_skipped_addressed_mail'
);

NOTIFY pgrst, 'reload schema';
