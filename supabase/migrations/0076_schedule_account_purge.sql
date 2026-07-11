-- ---------------------------------------------------------------------------
-- Venttly | Migration 0076 — Schedule the 30-day account purge
-- ---------------------------------------------------------------------------
-- Migration 0075 gave users self-serve deactivate + delete (30-day grace).
-- This wires the recurring job that actually finishes a deletion once the
-- grace window closes.
--
-- Why a cron -> edge function, not a pure SQL cron like 0034/0014?
--   Erasing an account means removing the auth.users row too, which is the
--   domain of the auth admin API (service role). public.users has no FK to
--   auth.users (0001), so SQL alone can't cascade across that boundary. The
--   `account-purge` edge function deletes BOTH sides per account; this cron
--   just pokes it once a day.
--
-- Security: the endpoint has verify_jwt = false (so the public anon key
-- can't reach it) and instead checks a shared secret header. The secret
-- lives in Vault under `account_purge_cron_secret` and is read at call time
-- below — it is NOT stored in this migration or in git.
--
-- ============================ ONE-TIME SETUP ==============================
-- Before (or right after) applying this migration, run these once against
-- the project. Pick any long random string for <SECRET> and use the SAME
-- value in both places:
--
--   1) Give the edge function the secret + deploy it:
--        supabase secrets set CRON_SECRET='<SECRET>'
--        supabase functions deploy account-purge
--
--   2) Store the same secret in Vault so this cron can read it:
--        select vault.create_secret('<SECRET>', 'account_purge_cron_secret');
--
-- To rotate later: update both, no code change needed.
-- ---------------------------------------------------------------------------

-- pg_cron is already enabled (migration 0014). pg_net powers the outbound
-- HTTP call to the function.
CREATE EXTENSION IF NOT EXISTS pg_net;

-- (Re)schedule daily at 03:15 UTC — off-peak, well clear of midnight so a
-- clock straddle can't double-count the grace window. Idempotent: drop any
-- prior job of this name first (pattern from migration 0034).
DO $$
DECLARE
    v_existing INT;
BEGIN
    SELECT jobid INTO v_existing
      FROM cron.job
     WHERE jobname = 'account_purge_daily';
    IF v_existing IS NOT NULL THEN
        PERFORM cron.unschedule(v_existing);
    END IF;

    PERFORM cron.schedule(
        'account_purge_daily',
        '15 3 * * *',
        $cron$
        SELECT net.http_post(
            url     := 'https://gyeibgaqrmnepbnfbtzc.functions.supabase.co/account-purge',
            headers := jsonb_build_object(
                'Content-Type',  'application/json',
                'x-cron-secret', (
                    SELECT decrypted_secret
                      FROM vault.decrypted_secrets
                     WHERE name = 'account_purge_cron_secret'
                )
            ),
            body    := jsonb_build_object('batch', 500)
        );
        $cron$
    );
END $$;

-- ---------------------------------------------------------------------------
-- Notes for operators
--   * Inspect runs:   select * from cron.job_run_details
--                      where jobid = (select jobid from cron.job
--                                     where jobname = 'account_purge_daily')
--                      order by start_time desc limit 20;
--   * The HTTP response lands in net._http_response; join on the request id
--     from the run details if you need the function's JSON body.
--   * Manual dry-run of the SQL side only:  select public.purge_due_accounts();
--     (deletes public rows for due accounts but NOT their auth.users row —
--      the edge function is the complete path).
-- ---------------------------------------------------------------------------
