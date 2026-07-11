-- ---------------------------------------------------------------------------
-- Venttly | Migration 0077 — Drain the email outbox on a schedule
-- ---------------------------------------------------------------------------
-- The email_outbox → email-dispatcher → Resend pipeline (0046 / 0072) had a
-- missing link: rows were queued by queue_email() but nothing drained them,
-- so transactional mail (verification codes, welcome, password reset) never
-- actually sent. This schedules the drain.
--
-- Every minute is the pg_cron floor and is fine for launch. Verification
-- codes tolerate a sub-minute delay; if you later want instant sends, add a
-- dashboard Database Webhook on email_outbox INSERT that POSTs to the same
-- function with the same x-cron-secret header (both callers are idempotent —
-- the dispatcher only pulls status = 'queued' and flips each row, so a webhook
-- and this cron can safely coexist).
--
-- Security: like account-purge (0076), the endpoint has verify_jwt = false and
-- is gated by the shared internal-cron secret. The secret value is the same
-- CRON_SECRET set on the functions; it is read here from the Vault entry
-- created for 0076 (`account_purge_cron_secret`) — one shared secret for all
-- internal cron targets, so there is nothing new to set up if 0076 is done.
--
-- ============================ PREREQUISITE ================================
-- Requires the Resend side to be live first (no-op / fast 500 until then):
--   supabase secrets set RESEND_API_KEY='<prod key>'
--   supabase secrets set RESEND_FROM_ADDRESS='hello@<verified-domain>'
--   supabase functions deploy email-dispatcher
-- The Vault secret `account_purge_cron_secret` from 0076 must already exist.
-- ---------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pg_net;

DO $$
DECLARE
    v_existing INT;
BEGIN
    SELECT jobid INTO v_existing
      FROM cron.job
     WHERE jobname = 'email_dispatch_every_minute';
    IF v_existing IS NOT NULL THEN
        PERFORM cron.unschedule(v_existing);
    END IF;

    PERFORM cron.schedule(
        'email_dispatch_every_minute',
        '* * * * *',
        $cron$
        SELECT net.http_post(
            url     := 'https://gyeibgaqrmnepbnfbtzc.functions.supabase.co/email-dispatcher',
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

-- ---------------------------------------------------------------------------
-- Inspect:  select * from cron.job_run_details
--            where jobid = (select jobid from cron.job
--                           where jobname = 'email_dispatch_every_minute')
--            order by start_time desc limit 20;
-- Pause while Resend is not yet configured (optional — the dispatcher just
-- returns a fast 500 until RESEND_API_KEY is set, doing no DB work):
--   update cron.job set active = false where jobname = 'email_dispatch_every_minute';
-- ---------------------------------------------------------------------------
