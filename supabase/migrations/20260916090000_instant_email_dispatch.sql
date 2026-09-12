-- Send mail when it is queued, not up to a minute later.
--
-- With the cron job restored, a verification code waits for the next tick —
-- somewhere between 0 and 60 seconds, averaging 30. For a welcome email that
-- is invisible. For a 6-digit code it is not: the person is sitting on the
-- code screen with the app saying "we sent a code", refreshing an inbox that
-- is empty. Half a minute of that is long enough to tap resend, which issues a
-- second code, invalidates the first, and produces exactly the "three codes
-- arrived at once" confusion seen in testing.
--
-- So the queue now pokes the dispatcher as soon as something lands in it, and
-- cron stops being the delivery mechanism and becomes purely the safety net —
-- for retries, for leases that expired, and for anything queued while the
-- function was briefly unreachable.
--
-- WHY A STATEMENT-LEVEL TRIGGER
--
-- FOR EACH STATEMENT, not FOR EACH ROW. The dispatcher claims a batch per
-- call, so one poke drains everything a statement inserted; per-row would fire
-- N HTTP requests to do the work of one. At the scale this app is being built
-- for that difference is the difference between a nudge and a stampede.
--
-- WHY THE THROTTLE
--
-- A burst — a moderation action mailing many people, a backfill — would
-- otherwise fire one request per statement with nothing to gain, since the
-- first call already claims up to 100 rows. The throttle collapses a burst
-- into one poke every two seconds. Worst case a message waits two seconds,
-- which is still fifteen times better than the cron floor.
--
-- pg_net is asynchronous: net.http_post writes to net.http_request_queue and a
-- background worker performs the request, so nothing here blocks the INSERT
-- that triggered it, and a slow or down dispatcher cannot make posting a vent
-- feel slow. If the surrounding transaction rolls back, the queued request
-- rolls back with it and no mail is announced for a row that never existed.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_net;

-- One row, holding the last time we poked. A table rather than a session
-- variable because the throttle has to hold across connections.
CREATE TABLE IF NOT EXISTS private.dispatch_pokes (
  channel     TEXT PRIMARY KEY,
  last_poke   TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE private.dispatch_pokes IS
  'Throttle state for immediate dispatch nudges. In the private schema: no client ever reads or writes this.';

REVOKE ALL ON TABLE private.dispatch_pokes FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.poke_email_dispatcher()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_secret TEXT;
  v_won    INT;
BEGIN
  -- Claim the right to poke. ON CONFLICT ... WHERE means the UPDATE only
  -- happens once the throttle window has passed, so ROW_COUNT tells us whether
  -- this statement is the one that won it. Two concurrent inserts cannot both
  -- poke, and neither blocks on the other for longer than the row lock is held.
  INSERT INTO private.dispatch_pokes AS p (channel, last_poke)
  VALUES ('email', now())
  ON CONFLICT (channel) DO UPDATE
    SET last_poke = now()
   WHERE p.last_poke < now() - INTERVAL '2 seconds';

  -- ROW_COUNT, not FOUND: FOUND is a plpgsql variable read directly and is not
  -- a GET DIAGNOSTICS item, and asking for it here is a runtime type error.
  GET DIAGNOSTICS v_won = ROW_COUNT;
  IF v_won = 0 THEN
    RETURN NULL;
  END IF;

  SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets
   WHERE name = 'account_purge_cron_secret';

  -- No secret means the call would be rejected. Say nothing and let cron and
  -- the watchdog handle it — raising here would fail the INSERT and stop
  -- somebody posting because an unrelated mail setting is wrong.
  IF v_secret IS NULL THEN
    RETURN NULL;
  END IF;

  -- Swallow everything.
  --
  -- Found in testing: without this, a role that cannot reach the net schema
  -- raises 42501 here, the exception propagates out of the trigger, and the
  -- INSERT into email_outbox fails. That would mean a pg_net problem stops
  -- people signing up, because signup queues a welcome email in the same
  -- transaction. An optimisation for how fast mail leaves must never be able
  -- to decide whether a write succeeds.
  --
  -- Nothing is lost by failing here: the row is already committed to the
  -- outbox, cron still drains it within the minute, and the watchdog still
  -- notices if it does not.
  BEGIN
    PERFORM net.http_post(
      url     := 'https://gyeibgaqrmnepbnfbtzc.functions.supabase.co/email-dispatcher',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'x-cron-secret', v_secret
      ),
      body    := '{}'::jsonb
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;

  RETURN NULL;
END $$;

COMMENT ON FUNCTION private.poke_email_dispatcher() IS
  'Asks the dispatcher to drain now, at most once every two seconds. Failure is silent on purpose: the cron job still sends everything, so a mail problem must never be able to fail a users write.';

DROP TRIGGER IF EXISTS email_outbox_poke ON public.email_outbox;

CREATE TRIGGER email_outbox_poke
  AFTER INSERT ON public.email_outbox
  FOR EACH STATEMENT
  EXECUTE FUNCTION private.poke_email_dispatcher();

COMMIT;

SELECT public.record_migration(
  '20260916090000', 'instant_email_dispatch'
);

NOTIFY pgrst, 'reload schema';
