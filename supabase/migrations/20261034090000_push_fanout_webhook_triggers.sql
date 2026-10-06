-- Wire the four tables that generate push to the notification-fanout worker.
--
-- The worker has been ACTIVE and correct for some time; nothing ever called
-- it. Its own header says "Database Webhooks submit only an event table +
-- primary key", and no such webhook existed, so push_delivery_outbox was never
-- filled and no notification has ever been sent.
--
-- WHY A MIGRATION RATHER THAN THE DASHBOARD
--
-- Supabase's Database Webhooks UI creates exactly these triggers, in the
-- supabase_functions schema, and nowhere else. They live only in whichever
-- database you clicked in: verify-migration-chain.sh replays this chain into
-- an empty container and would produce a database with no webhooks, staging
-- would need the same clicks repeated by hand, and neither drift would show up
-- until someone noticed notifications had quietly stopped. This repo keeps a
-- migration ledger and a chain verifier precisely so that state is not
-- something you remember to recreate.
--
-- It also follows the pattern 0076 already set for calling an edge function
-- from Postgres: net.http_post, with the shared secret read from the vault at
-- call time rather than written into the trigger definition.
--
-- WHAT IS SENT
--
--   { "type": "INSERT", "table": <table>, "record": { <id column>: <uuid> } }
--
-- The primary key and nothing else, which is the shape notification-fanout
-- parses and the reason it re-reads the row itself. A message's text never
-- leaves the database through this path -- the worker sends generic copy -- and
-- putting the row in the payload would hand it to pg_net's queue, the function
-- logs, and anything between. The id column is passed per trigger as TG_ARGV[0]
-- so the four triggers share one function without it needing a table lookup.
--
-- FAILURE BEHAVIOUR
--
-- net.http_post queues the request and returns immediately, so a slow or down
-- worker cannot hold open the transaction that is sending a chat message.
-- A missing vault secret returns NEW without calling anything: push stops,
-- messaging does not. The alternative -- raising -- would mean a misconfigured
-- notification pipeline takes the chat feature down with it, which is the wrong
-- trade for something whose whole job is to be a convenience.
--
-- Delivery is still gated twice beyond this: the worker refuses unless
-- PUSH_DELIVERY_ENABLED is on, and refuses any table outside its own EVENT_IDS
-- map.

BEGIN;

-- Fail here, at deploy time, rather than silently never sending. Mirrors the
-- check 20260915090000 makes for the cron secret.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM vault.decrypted_secrets
     WHERE name = 'push_fanout_webhook_secret'
       AND length(btrim(decrypted_secret)) > 0
  ) THEN
    -- Empty database: the chain is being replayed from zero (CI, a new
    -- laptop, a rebuild) and no secret can exist yet because nothing has been
    -- deployed. Refusing there makes the chain unreplayable, which is the one
    -- property the migration-replay job exists to check. On a database with
    -- people in it the refusal stands, because there it means somebody
    -- deployed without configuring the secret.
    IF EXISTS (SELECT 1 FROM auth.users LIMIT 1) THEN
      RAISE EXCEPTION
        'vault secret push_fanout_webhook_secret is missing or empty. The '
        'notification-fanout worker authenticates with it; creating these '
        'triggers without it would post an unauthenticated body on every '
        'message insert and be rejected every time. Add the secret, then '
        're-run this migration.';
    END IF;

    PERFORM vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'push_fanout_webhook_secret',
      'Placeholder minted while replaying migrations on an empty database. '
      'Replace it with the secret the notification-fanout worker expects.'
    );
    RAISE WARNING
      'push_fanout_webhook_secret was missing on an empty database, so a placeholder was minted to keep the migration chain replayable. Push fan-out will NOT authenticate until it is replaced.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION private.notify_push_fanout()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_secret TEXT;
  v_id     TEXT;
BEGIN
  SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets
   WHERE name = 'push_fanout_webhook_secret';

  -- No secret, no push. Never take the write down with it.
  IF v_secret IS NULL OR length(btrim(v_secret)) = 0 THEN
    RETURN NEW;
  END IF;

  v_id := pg_catalog.to_jsonb(NEW) ->> TG_ARGV[0];
  IF v_id IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url     := 'https://gyeibgaqrmnepbnfbtzc.functions.supabase.co/notification-fanout',
    headers := pg_catalog.jsonb_build_object(
      'Content-Type',     'application/json',
      'x-webhook-secret', v_secret
    ),
    body    := pg_catalog.jsonb_build_object(
      'type',   'INSERT',
      'table',  TG_TABLE_NAME,
      'record', pg_catalog.jsonb_build_object(TG_ARGV[0], v_id)
    )
  );

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.notify_push_fanout() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION private.notify_push_fanout() IS
  'AFTER INSERT bridge from the four push-generating tables to the '
  'notification-fanout edge function. Sends only the table name and primary '
  'key; the worker re-reads the row. Takes the id column as TG_ARGV[0].';

-- The four tables, and the id column each one is keyed by. These names are the
-- worker''s EVENT_IDS map; anything else it rejects as invalid_webhook_event.

DROP TRIGGER IF EXISTS push_fanout_on_insert ON public.chat_messages;
CREATE TRIGGER push_fanout_on_insert
  AFTER INSERT ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION private.notify_push_fanout('message_id');

DROP TRIGGER IF EXISTS push_fanout_on_insert ON public.tribe_messages;
CREATE TRIGGER push_fanout_on_insert
  AFTER INSERT ON public.tribe_messages
  FOR EACH ROW EXECUTE FUNCTION private.notify_push_fanout('message_id');

DROP TRIGGER IF EXISTS push_fanout_on_insert ON public.friendships;
CREATE TRIGGER push_fanout_on_insert
  AFTER INSERT ON public.friendships
  FOR EACH ROW EXECUTE FUNCTION private.notify_push_fanout('friendship_id');

DROP TRIGGER IF EXISTS push_fanout_on_insert ON public.notifications;
CREATE TRIGGER push_fanout_on_insert
  AFTER INSERT ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION private.notify_push_fanout('notification_id');

SELECT public.record_migration(
  '20261034090000', 'push_fanout_webhook_triggers'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
