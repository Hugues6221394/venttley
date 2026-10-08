-- Broadcasts reach members.
--
-- Until now a broadcast was a row in public.broadcasts that nothing in the app
-- read. This delivers each one as an 'admin_broadcast' notification (which the
-- app already renders, and which the push trigger on notifications turns into
-- the usual generic push), to everyone or to one tribe, now or at a scheduled
-- time. A cron job delivers in bounded batches, so a large audience never sits
-- in one transaction. Withdrawing a broadcast stops delivery and removes the
-- notifications it already created.
--
-- Broadcasts that exist before this migration are recorded as predating
-- delivery and are never sent: nobody approved them for a push.
BEGIN;

CREATE TABLE private.broadcast_deliveries (
  broadcast_id  UUID PRIMARY KEY REFERENCES public.broadcasts(broadcast_id) ON DELETE CASCADE,
  state         TEXT NOT NULL DEFAULT 'waiting' CHECK (state IN
                  ('waiting','delivering','delivered','expired','withdrawing','withdrawn','predates_delivery')),
  audience_size INTEGER CHECK (audience_size IS NULL OR audience_size >= 0),
  cursor        UUID,
  delivered     INTEGER NOT NULL DEFAULT 0 CHECK (delivered >= 0),
  withdrawn     INTEGER NOT NULL DEFAULT 0 CHECK (withdrawn >= 0),
  started_at    TIMESTAMPTZ,
  finished_at   TIMESTAMPTZ,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX broadcast_deliveries_open_idx ON private.broadcast_deliveries (state)
  WHERE state IN ('waiting','delivering','withdrawing');
ALTER TABLE private.broadcast_deliveries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.broadcast_deliveries FROM PUBLIC, anon, authenticated, service_role;

INSERT INTO private.broadcast_deliveries (broadcast_id, state, finished_at)
SELECT broadcast_id, 'predates_delivery', now() FROM public.broadcasts
ON CONFLICT DO NOTHING;

-- Withdrawal finds a broadcast's notifications without scanning every inbox.
CREATE INDEX IF NOT EXISTS notifications_broadcast_idx
  ON public.notifications (subject_id) WHERE kind = 'admin_broadcast';

-- Every publication path (this one, the approval workflow, the legacy RPC)
-- inserts into public.broadcasts; delivery follows from the insert.
CREATE FUNCTION private.queue_broadcast_delivery() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO private.broadcast_deliveries (broadcast_id) VALUES (NEW.broadcast_id)
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.queue_broadcast_delivery() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER queue_broadcast_delivery AFTER INSERT ON public.broadcasts
  FOR EACH ROW EXECUTE FUNCTION private.queue_broadcast_delivery();

-- The tribe a broadcast targets, or NULL for everyone. Anything else is not
-- deliverable and is treated as an empty audience rather than everyone.
CREATE FUNCTION private.broadcast_tribe(p_audience JSONB) RETURNS UUID
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p_audience ->> 'scope' = 'tribe'
     AND (p_audience ->> 'value') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    THEN (p_audience ->> 'value')::UUID
  END
$$;

-- Who a broadcast reaches: active accounts that are not leaving.
CREATE FUNCTION private.broadcast_audience_count(p_tribe UUID) RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT count(*)::INTEGER FROM public.users u
  WHERE u.account_status = 'active' AND u.deactivated_at IS NULL AND u.deletion_requested_at IS NULL
    AND (p_tribe IS NULL OR EXISTS (
      SELECT 1 FROM public.tribe_members m WHERE m.tribe_id = p_tribe AND m.user_id = u.user_id))
$$;
REVOKE ALL ON FUNCTION private.broadcast_tribe(JSONB), private.broadcast_audience_count(UUID)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION private.deliver_broadcasts(p_batch INTEGER DEFAULT 1000) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d       private.broadcast_deliveries%ROWTYPE;
  b       public.broadcasts%ROWTYPE;
  scope   TEXT;
  tribe   UUID;
  n       INTEGER;
  last_id UUID;
  budget  INTEGER := GREATEST(1, LEAST(COALESCE(p_batch, 1000), 5000));
  done    INTEGER := 0;
BEGIN
  -- Withdrawn broadcasts first: a mistake should leave inboxes faster than it
  -- arrived.
  UPDATE private.broadcast_deliveries x
     SET state = CASE WHEN x.delivered > x.withdrawn THEN 'withdrawing' ELSE 'withdrawn' END,
         finished_at = CASE WHEN x.delivered > x.withdrawn THEN NULL ELSE clock_timestamp() END,
         updated_at = clock_timestamp()
    FROM public.broadcasts pb
   WHERE pb.broadcast_id = x.broadcast_id AND NOT pb.is_active
     AND x.state IN ('waiting','delivering','delivered','expired');

  FOR d IN SELECT * FROM private.broadcast_deliveries
            WHERE state = 'withdrawing' ORDER BY updated_at LIMIT 5 FOR UPDATE SKIP LOCKED
  LOOP
    WITH gone AS (
      DELETE FROM public.notifications
       WHERE notification_id IN (
         SELECT notification_id FROM public.notifications
          WHERE kind = 'admin_broadcast' AND subject_id = d.broadcast_id LIMIT 5000)
      RETURNING 1)
    SELECT count(*)::INTEGER INTO n FROM gone;
    UPDATE private.broadcast_deliveries
       SET withdrawn = withdrawn + n,
           state = CASE WHEN n < 5000 THEN 'withdrawn' ELSE state END,
           finished_at = CASE WHEN n < 5000 THEN clock_timestamp() END,
           updated_at = clock_timestamp()
     WHERE broadcast_id = d.broadcast_id;
  END LOOP;

  FOR d IN SELECT x.* FROM private.broadcast_deliveries x
             JOIN public.broadcasts pb ON pb.broadcast_id = x.broadcast_id
            WHERE x.state IN ('waiting','delivering') AND pb.is_active
              AND COALESCE(pb.scheduled_for, pb.sent_at, pb.created_at) <= now()
            ORDER BY COALESCE(pb.scheduled_for, pb.sent_at, pb.created_at)
            LIMIT 5 FOR UPDATE OF x SKIP LOCKED
  LOOP
    EXIT WHEN budget <= 0;
    SELECT * INTO b FROM public.broadcasts WHERE broadcast_id = d.broadcast_id;
    IF b.expires_at IS NOT NULL AND b.expires_at <= now() THEN
      UPDATE private.broadcast_deliveries
         SET state = 'expired', finished_at = clock_timestamp(), updated_at = clock_timestamp()
       WHERE broadcast_id = d.broadcast_id;
      CONTINUE;
    END IF;
    scope := b.audience ->> 'scope';
    tribe := private.broadcast_tribe(b.audience);
    IF scope IS DISTINCT FROM 'all' AND tribe IS NULL THEN
      -- An audience this function cannot resolve is never widened to everyone.
      UPDATE private.broadcast_deliveries
         SET state = 'delivered', audience_size = 0, started_at = clock_timestamp(),
             finished_at = clock_timestamp(), updated_at = clock_timestamp()
       WHERE broadcast_id = d.broadcast_id;
      CONTINUE;
    END IF;
    IF d.state = 'waiting' THEN
      UPDATE private.broadcast_deliveries
         SET state = 'delivering', started_at = clock_timestamp(),
             audience_size = private.broadcast_audience_count(tribe), updated_at = clock_timestamp()
       WHERE broadcast_id = d.broadcast_id;
    END IF;

    WITH targets AS MATERIALIZED (
      SELECT u.user_id FROM public.users u
       WHERE (d.cursor IS NULL OR u.user_id > d.cursor)
         AND u.account_status = 'active' AND u.deactivated_at IS NULL AND u.deletion_requested_at IS NULL
         AND (tribe IS NULL OR EXISTS (
           SELECT 1 FROM public.tribe_members m WHERE m.tribe_id = tribe AND m.user_id = u.user_id))
       ORDER BY u.user_id
       LIMIT budget
    ), sent AS (
      INSERT INTO public.notifications (user_id, kind, payload, subject_type, subject_id)
      SELECT t.user_id, 'admin_broadcast',
             jsonb_build_object('title', b.title, 'body', b.body, 'urgency', b.urgency,
                                'broadcast_id', b.broadcast_id, 'source', 'venttly_team'),
             'broadcast', b.broadcast_id
        FROM targets t
      RETURNING 1
    )
    SELECT (SELECT count(*)::INTEGER FROM sent),
           (SELECT t.user_id FROM targets t ORDER BY t.user_id DESC LIMIT 1)
      INTO n, last_id;

    UPDATE private.broadcast_deliveries
       SET delivered = delivered + n,
           cursor = COALESCE(last_id, cursor),
           state = CASE WHEN n < budget THEN 'delivered' ELSE 'delivering' END,
           finished_at = CASE WHEN n < budget THEN clock_timestamp() END,
           updated_at = clock_timestamp()
     WHERE broadcast_id = d.broadcast_id;
    IF n > 0 THEN
      UPDATE public.broadcasts SET delivered_count = delivered_count + n
       WHERE broadcast_id = d.broadcast_id;
    END IF;
    budget := budget - n;
    done := done + n;
  END LOOP;
  RETURN done;
END $$;
REVOKE ALL ON FUNCTION private.deliver_broadcasts(INTEGER) FROM PUBLIC, anon, authenticated, service_role;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'broadcast-delivery';
SELECT cron.schedule('broadcast-delivery', '* * * * *', 'SELECT private.deliver_broadcasts(1000)');

CREATE FUNCTION private.require_broadcast_publisher() RETURNS VOID
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(), ARRAY['super_admin','admin']) THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;
END $$;
REVOKE ALL ON FUNCTION private.require_broadcast_publisher() FROM PUBLIC, anon, authenticated, service_role;

-- How many members a broadcast would reach, for the composer.
CREATE FUNCTION public.admin_broadcast_audience(p_tribe UUID DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.tribes%ROWTYPE;
BEGIN
  PERFORM private.require_broadcast_publisher();
  IF NOT public.claim_rate_limit('broadcast_audience_read', 60, 60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_tribe IS NOT NULL THEN
    SELECT * INTO t FROM public.tribes WHERE tribe_id = p_tribe;
    IF NOT FOUND THEN RAISE EXCEPTION 'tribe_not_found'; END IF;
  END IF;
  RETURN jsonb_build_object('tribe_id', p_tribe, 'tribe_name', t.name,
                            'members', private.broadcast_audience_count(p_tribe));
END $$;

-- Tribes a broadcast can target, by name.
CREATE FUNCTION public.admin_broadcast_tribes(p_query TEXT DEFAULT '') RETURNS TABLE
  (tribe_id UUID, name TEXT, member_count INTEGER)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_broadcast_publisher();
  IF NOT public.claim_rate_limit('broadcast_tribes_read', 60, 60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  RETURN QUERY
    SELECT t.tribe_id, t.name::TEXT, t.member_count::INTEGER FROM public.tribes t
     WHERE t.is_active AND t.deletion_requested_at IS NULL
       AND (COALESCE(btrim(p_query), '') = '' OR t.name ILIKE '%' || replace(replace(btrim(p_query), '%', ''), '_', '') || '%')
     ORDER BY t.member_count DESC NULLS LAST, t.name
     LIMIT 25;
END $$;

CREATE FUNCTION public.admin_publish_broadcast(
  p_operation     UUID,
  p_title         TEXT,
  p_body          TEXT,
  p_urgency       TEXT,
  p_tribe         UUID DEFAULT NULL,
  p_scheduled_for TIMESTAMPTZ DEFAULT NULL,
  p_expires_at    TIMESTAMPTZ DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  actor   UUID := auth.uid();
  result  UUID;
  starts  TIMESTAMPTZ := COALESCE(p_scheduled_for, now());
  request JSONB := jsonb_build_object('title', p_title, 'body', p_body, 'urgency', p_urgency,
                     'tribe', p_tribe, 'scheduled_for', p_scheduled_for, 'expires_at', p_expires_at);
BEGIN
  PERFORM private.require_broadcast_publisher();
  PERFORM private.require_aal2();
  IF p_operation IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
  result := private.admin_operation_existing(actor, p_operation, 'broadcast.publish', request);
  IF result IS NOT NULL THEN RETURN result; END IF;
  IF p_title IS NULL OR length(btrim(p_title)) NOT BETWEEN 1 AND 120 OR p_title <> btrim(p_title)
     OR p_body IS NULL OR length(btrim(p_body)) NOT BETWEEN 1 AND 1000 OR p_body <> btrim(p_body)
     OR p_title ~ '[[:cntrl:]]' OR p_body ~ '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]'
     OR p_urgency IS NULL OR p_urgency NOT IN ('info','warning','critical','crisis') THEN
    RAISE EXCEPTION 'invalid_broadcast_payload';
  END IF;
  IF p_scheduled_for IS NOT NULL AND (p_scheduled_for <= now() OR p_scheduled_for > now() + interval '30 days') THEN
    RAISE EXCEPTION 'invalid_schedule';
  END IF;
  IF p_expires_at IS NOT NULL AND (p_expires_at <= starts + interval '10 minutes' OR p_expires_at > starts + interval '30 days') THEN
    RAISE EXCEPTION 'invalid_expiry';
  END IF;
  IF p_tribe IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.tribes WHERE tribe_id = p_tribe AND is_active AND deletion_requested_at IS NULL) THEN
    RAISE EXCEPTION 'tribe_not_found';
  END IF;
  IF NOT public.claim_rate_limit('broadcast_publish', 3600, 20) THEN RAISE EXCEPTION 'rate_limited'; END IF;

  INSERT INTO public.broadcasts (title, body, urgency, audience, scheduled_for, expires_at, sent_at, sent_by)
  VALUES (p_title, p_body, p_urgency,
          CASE WHEN p_tribe IS NULL THEN '{"scope":"all"}'::JSONB
               ELSE jsonb_build_object('scope', 'tribe', 'value', p_tribe::TEXT) END,
          p_scheduled_for, p_expires_at,
          CASE WHEN p_scheduled_for IS NULL THEN now() END, actor)
  RETURNING broadcast_id INTO result;

  PERFORM private.record_admin_operation(actor, p_operation, 'broadcast.publish', request, result);
  PERFORM private.record_operational_audit(actor, 'broadcast.publish', 'broadcast', result, p_title,
    CASE WHEN p_scheduled_for IS NULL THEN 'Published a broadcast.' ELSE 'Scheduled a broadcast.' END,
    jsonb_build_object('urgency', p_urgency, 'tribe', p_tribe, 'scheduled_for', p_scheduled_for,
                       'expires_at', p_expires_at));
  RETURN result;
END $$;

-- Stops delivery and removes what was delivered. The row and its history stay.
CREATE FUNCTION public.admin_withdraw_broadcast(p_operation UUID, p_broadcast UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE actor UUID := auth.uid(); label TEXT; request JSONB := jsonb_build_object('broadcast', p_broadcast);
BEGIN
  PERFORM private.require_broadcast_publisher();
  PERFORM private.require_aal2();
  IF p_operation IS NULL OR p_broadcast IS NULL THEN RAISE EXCEPTION 'invalid_input'; END IF;
  IF private.admin_operation_existing(actor, p_operation, 'broadcast.withdraw', request) IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('broadcast_withdraw', 60, 20) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT title INTO label FROM public.broadcasts WHERE broadcast_id = p_broadcast FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
  UPDATE public.broadcasts SET is_active = false WHERE broadcast_id = p_broadcast AND is_active;
  PERFORM private.record_admin_operation(actor, p_operation, 'broadcast.withdraw', request, p_broadcast);
  PERFORM private.record_operational_audit(actor, 'broadcast.withdraw', 'broadcast', p_broadcast, label,
    'Withdrew a broadcast and its notifications.', '{}'::JSONB);
END $$;

-- The console's register: each broadcast with where its delivery stands.
CREATE FUNCTION public.admin_broadcast_register(p_limit INTEGER DEFAULT 100) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_broadcast_publisher();
  IF NOT public.claim_rate_limit('broadcast_register_read', 60, 120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  RETURN (SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC), '[]'::JSONB) FROM (
    SELECT b.broadcast_id, b.title, b.body, b.urgency, b.audience, b.scheduled_for, b.sent_at, b.expires_at,
           b.is_active, b.created_at, b.delivered_count,
           COALESCE(d.state, 'predates_delivery') AS delivery_state,
           d.audience_size, d.withdrawn, d.started_at, d.finished_at,
           t.name AS tribe_name, COALESCE(s.display_name, 'Former staff') AS sent_by_name
      FROM public.broadcasts b
      LEFT JOIN private.broadcast_deliveries d ON d.broadcast_id = b.broadcast_id
      LEFT JOIN public.tribes t ON t.tribe_id = private.broadcast_tribe(b.audience)
      LEFT JOIN public.users s ON s.user_id = b.sent_by
     ORDER BY b.created_at DESC
     LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 100), 200))) x);
END $$;

REVOKE ALL ON FUNCTION public.admin_broadcast_audience(UUID), public.admin_broadcast_tribes(TEXT),
  public.admin_publish_broadcast(UUID,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ),
  public.admin_withdraw_broadcast(UUID,UUID), public.admin_broadcast_register(INTEGER)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_broadcast_audience(UUID), public.admin_broadcast_tribes(TEXT),
  public.admin_publish_broadcast(UUID,TEXT,TEXT,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ),
  public.admin_withdraw_broadcast(UUID,UUID), public.admin_broadcast_register(INTEGER)
  TO authenticated;

SELECT public.record_migration('20261088090000', 'broadcasts_reach_members');
COMMIT;
