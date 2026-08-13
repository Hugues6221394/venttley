-- Close the highest-risk trust-boundary gaps before feature expansion.
-- Every object in this migration is safe to replay and defaults privileged or
-- externally processed work to denied/disabled until explicitly configured.

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
-- RLS policies resolve narrowly granted helpers in this schema. USAGE does
-- not make tables or functions callable; their object grants still deny it.
GRANT USAGE ON SCHEMA private TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Durable, idempotent push outbox. It contains routing identifiers only;
--    user-authored message/post text never enters a third-party push payload.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.push_delivery_outbox (
  delivery_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_key TEXT NOT NULL,
  user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  event_kind TEXT NOT NULL CHECK (
    event_kind IN ('chat', 'tribe_chat', 'friend_request', 'notification')
  ),
  event_data JSONB NOT NULL DEFAULT '{}'::JSONB,
  status TEXT NOT NULL DEFAULT 'queued' CHECK (
    status IN ('queued', 'processing', 'sent', 'dead')
  ),
  attempts INT NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 20),
  available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  lease_expires_at TIMESTAMPTZ,
  last_error_code TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at TIMESTAMPTZ,
  UNIQUE (event_key, user_id)
);

CREATE INDEX IF NOT EXISTS push_delivery_outbox_claim_idx
  ON public.push_delivery_outbox (available_at, created_at)
  WHERE status IN ('queued', 'processing');

ALTER TABLE public.push_delivery_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_delivery_outbox FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.push_delivery_outbox TO service_role;

-- An FCM/APNs token represents one installation and must never remain bound to
-- a previous account after sign-out/account switching. Keep the most recently
-- seen owner before enforcing global token uniqueness.
DELETE FROM public.push_tokens AS stale
USING public.push_tokens AS keeper
WHERE stale.token = keeper.token
  AND (
    stale.last_seen_at < keeper.last_seen_at
    OR (
      stale.last_seen_at = keeper.last_seen_at
      AND stale.user_id::TEXT < keeper.user_id::TEXT
    )
  );

CREATE UNIQUE INDEX IF NOT EXISTS push_tokens_token_unique
  ON public.push_tokens (token);

CREATE OR REPLACE FUNCTION public.register_push_token(
  p_token TEXT,
  p_platform TEXT,
  p_locale TEXT DEFAULT NULL,
  p_app_version TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF length(COALESCE(p_token, '')) NOT BETWEEN 16 AND 4096 THEN
    RAISE EXCEPTION 'invalid_push_token';
  END IF;
  IF p_platform NOT IN ('android', 'ios', 'web') THEN
    RAISE EXCEPTION 'invalid platform';
  END IF;
  INSERT INTO public.push_tokens (
    user_id, platform, token, locale, app_version
  ) VALUES (
    v_me, p_platform, p_token, left(p_locale, 35), left(p_app_version, 40)
  )
  ON CONFLICT (token) DO UPDATE
     SET user_id = EXCLUDED.user_id,
         platform = EXCLUDED.platform,
         locale = EXCLUDED.locale,
         app_version = EXCLUDED.app_version,
         last_seen_at = now();
END;
$$;

REVOKE ALL ON FUNCTION public.register_push_token(TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_push_token(TEXT, TEXT, TEXT, TEXT)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.enqueue_push_event(
  p_table TEXT,
  p_event_id UUID
) RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_inserted INT := 0;
  v_message RECORD;
  v_room RECORD;
  v_friend RECORD;
  v_notification RECORD;
BEGIN
  IF p_event_id IS NULL THEN RAISE EXCEPTION 'event_id_required'; END IF;

  IF p_table = 'chat_messages' THEN
    SELECT m.message_id, m.room_id, m.sender_id
      INTO v_message
      FROM public.chat_messages AS m
     WHERE m.message_id = p_event_id
       AND m.deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'event_not_found'; END IF;

    SELECT r.room_kind, r.initiated_by, r.received_by
      INTO v_room
      FROM public.chat_rooms AS r
     WHERE r.room_id = v_message.room_id
       AND r.room_status = 'active';
    IF NOT FOUND THEN RETURN 0; END IF;

    IF v_room.room_kind = 'group' THEN
      INSERT INTO public.push_delivery_outbox (
        event_key, user_id, event_kind, event_data
      )
      SELECT
        'chat_messages:' || v_message.message_id::TEXT,
        member.user_id,
        'chat',
        jsonb_build_object(
          'room_id', v_message.room_id,
          'message_id', v_message.message_id
        )
      FROM public.chat_room_members AS member
      WHERE member.room_id = v_message.room_id
        AND member.left_at IS NULL
        AND member.user_id IS DISTINCT FROM v_message.sender_id
        AND NOT EXISTS (
          SELECT 1 FROM public.dm_room_prefs AS pref
           WHERE pref.room_id = v_message.room_id
             AND pref.user_id = member.user_id
             AND pref.muted
        )
      ON CONFLICT (event_key, user_id) DO NOTHING;
    ELSE
      INSERT INTO public.push_delivery_outbox (
        event_key, user_id, event_kind, event_data
      )
      SELECT
        'chat_messages:' || v_message.message_id::TEXT,
        peer.user_id,
        'chat',
        jsonb_build_object(
          'room_id', v_message.room_id,
          'message_id', v_message.message_id
        )
      FROM (
        VALUES (
          CASE WHEN v_room.initiated_by = v_message.sender_id
               THEN v_room.received_by ELSE v_room.initiated_by END
        )
      ) AS peer(user_id)
      WHERE peer.user_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.dm_room_prefs AS pref
           WHERE pref.room_id = v_message.room_id
             AND pref.user_id = peer.user_id
             AND pref.muted
        )
      ON CONFLICT (event_key, user_id) DO NOTHING;
    END IF;

  ELSIF p_table = 'tribe_messages' THEN
    SELECT message.message_id, message.tribe_id, message.sender_id, tribe.slug
      INTO v_message
      FROM public.tribe_messages AS message
      JOIN public.tribes AS tribe ON tribe.tribe_id = message.tribe_id
     WHERE message.message_id = p_event_id
       AND message.deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'event_not_found'; END IF;

    INSERT INTO public.push_delivery_outbox (
      event_key, user_id, event_kind, event_data
    )
    SELECT
      'tribe_messages:' || v_message.message_id::TEXT,
      member.user_id,
      'tribe_chat',
      jsonb_build_object(
        'tribe_slug', v_message.slug,
        'message_id', v_message.message_id,
        'payload', 'tribe_chat:' || v_message.slug || '/' || v_message.message_id::TEXT
      )
    FROM public.tribe_members AS member
    WHERE member.tribe_id = v_message.tribe_id
      AND member.user_id IS DISTINCT FROM v_message.sender_id
    ON CONFLICT (event_key, user_id) DO NOTHING;

  ELSIF p_table = 'friendships' THEN
    SELECT friendship_id, user_a, user_b, requested_by, status
      INTO v_friend
      FROM public.friendships
     WHERE friendship_id = p_event_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'event_not_found'; END IF;
    IF v_friend.status <> 'pending' THEN RETURN 0; END IF;

    INSERT INTO public.push_delivery_outbox (
      event_key, user_id, event_kind, event_data
    ) VALUES (
      'friendships:' || v_friend.friendship_id::TEXT,
      CASE WHEN v_friend.requested_by = v_friend.user_a
           THEN v_friend.user_b ELSE v_friend.user_a END,
      'friend_request',
      jsonb_build_object('friendship_id', v_friend.friendship_id)
    ) ON CONFLICT (event_key, user_id) DO NOTHING;

  ELSIF p_table = 'notifications' THEN
    SELECT notification_id, user_id
      INTO v_notification
      FROM public.notifications
     WHERE notification_id = p_event_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'event_not_found'; END IF;

    INSERT INTO public.push_delivery_outbox (
      event_key, user_id, event_kind, event_data
    ) VALUES (
      'notifications:' || v_notification.notification_id::TEXT,
      v_notification.user_id,
      'notification',
      jsonb_build_object('notification_id', v_notification.notification_id)
    ) ON CONFLICT (event_key, user_id) DO NOTHING;
  ELSE
    RAISE EXCEPTION 'unsupported_event_table';
  END IF;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_push_deliveries(p_batch INT DEFAULT 100)
RETURNS TABLE (
  delivery_id UUID,
  attempts INT,
  user_id UUID,
  event_kind TEXT,
  event_data JSONB
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH expired AS (
    UPDATE public.push_delivery_outbox AS outbox
       SET status = 'dead',
           lease_expires_at = NULL,
           last_error_code = COALESCE(outbox.last_error_code, 'lease_exhausted')
     WHERE outbox.status = 'processing'
       AND outbox.attempts >= 8
       AND outbox.lease_expires_at < now()
    RETURNING outbox.delivery_id
  ), candidates AS (
    SELECT outbox.delivery_id
      FROM public.push_delivery_outbox AS outbox
     WHERE outbox.attempts < 8
       AND outbox.available_at <= now()
       AND (
         outbox.status = 'queued'
         OR (outbox.status = 'processing' AND outbox.lease_expires_at < now())
       )
     ORDER BY outbox.available_at, outbox.created_at
     FOR UPDATE SKIP LOCKED
     LIMIT LEAST(GREATEST(COALESCE(p_batch, 100), 1), 250)
  )
  UPDATE public.push_delivery_outbox AS outbox
     SET status = 'processing',
         attempts = outbox.attempts + 1,
         lease_expires_at = now() + INTERVAL '2 minutes'
    FROM candidates
   WHERE outbox.delivery_id = candidates.delivery_id
  RETURNING outbox.delivery_id, outbox.attempts, outbox.user_id,
            outbox.event_kind, outbox.event_data;
$$;

CREATE OR REPLACE FUNCTION public.complete_push_delivery(
  p_delivery_id UUID,
  p_attempt INT,
  p_succeeded BOOLEAN,
  p_error_code TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.push_delivery_outbox AS outbox
     SET status = CASE
           WHEN p_succeeded THEN 'sent'
           WHEN outbox.attempts >= 8 THEN 'dead'
           ELSE 'queued'
         END,
         sent_at = CASE WHEN p_succeeded THEN now() ELSE NULL END,
         available_at = CASE
           WHEN p_succeeded THEN outbox.available_at
           ELSE now() + make_interval(
             secs => LEAST(3600, (5 * power(2, LEAST(outbox.attempts, 9)))::INT)
           )
         END,
         lease_expires_at = NULL,
         last_error_code = CASE
           WHEN p_succeeded THEN NULL
           ELSE left(COALESCE(p_error_code, 'unknown'), 80)
         END
   WHERE outbox.delivery_id = p_delivery_id
     AND outbox.status = 'processing'
     AND outbox.attempts = p_attempt;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_push_event(TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_push_deliveries(INT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_push_delivery(UUID, INT, BOOLEAN, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_push_event(TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_push_deliveries(INT) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_push_delivery(UUID, INT, BOOLEAN, TEXT)
  TO service_role;

-- Transactional email uses the same lease/attempt discipline as push. Resend
-- receives the outbox UUID as an idempotency key, so a timeout after provider
-- acceptance can be safely retried within Resend's 24-hour dedupe window.
ALTER TABLE public.email_outbox
  ADD COLUMN IF NOT EXISTS available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS lease_expires_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS email_outbox_claim_idx
  ON public.email_outbox (available_at, created_at)
  WHERE status IN ('queued', 'sending');

CREATE OR REPLACE FUNCTION public.claim_email_deliveries(p_batch INT DEFAULT 25)
RETURNS TABLE (
  outbox_id UUID,
  user_id UUID,
  template TEXT,
  variables JSONB,
  attempts INT
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
            outbox.variables, outbox.attempts;
$$;

CREATE OR REPLACE FUNCTION public.complete_email_delivery(
  p_outbox_id UUID,
  p_attempt INT,
  p_outcome TEXT,
  p_error_code TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_outcome NOT IN ('sent', 'skipped', 'retry', 'failed') THEN
    RAISE EXCEPTION 'invalid_email_outcome';
  END IF;
  UPDATE public.email_outbox AS outbox
     SET status = CASE
           WHEN p_outcome = 'sent' THEN 'sent'
           WHEN p_outcome = 'skipped' THEN 'skipped'
           WHEN p_outcome = 'failed' OR outbox.attempts >= 8 THEN 'failed'
           ELSE 'queued'
         END,
         sent_at = CASE WHEN p_outcome = 'sent' THEN now() ELSE NULL END,
         available_at = CASE
           WHEN p_outcome = 'retry' AND outbox.attempts < 8 THEN
             now() + make_interval(
               secs => LEAST(3600, (5 * power(2, LEAST(outbox.attempts, 9)))::INT)
             )
           ELSE outbox.available_at
         END,
         lease_expires_at = NULL,
         last_error = CASE
           WHEN p_outcome = 'sent' THEN NULL
           ELSE left(COALESCE(p_error_code, p_outcome), 80)
         END
   WHERE outbox.outbox_id = p_outbox_id
     AND outbox.status = 'sending'
     AND outbox.attempts = p_attempt;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_email_deliveries(INT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_email_delivery(UUID, INT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_email_deliveries(INT) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_email_delivery(UUID, INT, TEXT, TEXT)
  TO service_role;

-- Stripe can redeliver and reorder signed events. A receipt prevents duplicate
-- application, while the provider event timestamp prevents an older event
-- from overwriting newer subscription state.
ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS last_stripe_event_created BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_stripe_event_id TEXT;

CREATE TABLE IF NOT EXISTS public.stripe_webhook_events (
  event_id TEXT PRIMARY KEY,
  event_created BIGINT NOT NULL,
  event_type TEXT NOT NULL,
  subscription_id TEXT NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS stripe_webhook_events_received_idx
  ON public.stripe_webhook_events (received_at);
ALTER TABLE public.stripe_webhook_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.stripe_webhook_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.stripe_webhook_events TO service_role;

CREATE OR REPLACE FUNCTION public.apply_stripe_subscription_event(
  p_event_id TEXT,
  p_event_created BIGINT,
  p_event_type TEXT,
  p_subscription_id TEXT,
  p_user_id UUID,
  p_customer_id TEXT,
  p_status TEXT,
  p_tier TEXT,
  p_price_id TEXT,
  p_renews_at TIMESTAMPTZ,
  p_canceled_at TIMESTAMPTZ,
  p_period_start TIMESTAMPTZ,
  p_period_end TIMESTAMPTZ
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_applied BOOLEAN := FALSE;
BEGIN
  IF length(COALESCE(p_event_id, '')) NOT BETWEEN 3 AND 255
     OR p_event_created IS NULL OR p_event_created < 0
     OR length(COALESCE(p_subscription_id, '')) NOT BETWEEN 3 AND 255
     OR p_user_id IS NULL
  THEN
    RAISE EXCEPTION 'invalid_stripe_event';
  END IF;

  INSERT INTO public.stripe_webhook_events (
    event_id, event_created, event_type, subscription_id
  ) VALUES (
    p_event_id, p_event_created, left(COALESCE(p_event_type, 'unknown'), 100),
    p_subscription_id
  ) ON CONFLICT (event_id) DO NOTHING;
  IF NOT FOUND THEN RETURN FALSE; END IF;

  INSERT INTO public.subscriptions (
    subscription_id, user_id, stripe_customer_id, status, tier, price_id,
    renews_at, canceled_at, current_period_start, current_period_end,
    last_stripe_event_created, last_stripe_event_id, updated_at
  ) VALUES (
    p_subscription_id, p_user_id, p_customer_id, p_status, p_tier, p_price_id,
    p_renews_at, p_canceled_at, p_period_start, p_period_end,
    p_event_created, p_event_id, now()
  )
  ON CONFLICT (subscription_id) DO UPDATE
     SET user_id = EXCLUDED.user_id,
         stripe_customer_id = EXCLUDED.stripe_customer_id,
         status = EXCLUDED.status,
         tier = EXCLUDED.tier,
         price_id = EXCLUDED.price_id,
         renews_at = EXCLUDED.renews_at,
         canceled_at = EXCLUDED.canceled_at,
         current_period_start = EXCLUDED.current_period_start,
         current_period_end = EXCLUDED.current_period_end,
         last_stripe_event_created = EXCLUDED.last_stripe_event_created,
         last_stripe_event_id = EXCLUDED.last_stripe_event_id,
         updated_at = now()
   WHERE EXCLUDED.last_stripe_event_created >=
         public.subscriptions.last_stripe_event_created
  RETURNING TRUE INTO v_applied;

  DELETE FROM public.stripe_webhook_events AS receipt
   WHERE receipt.event_id IN (
     SELECT old.event_id
       FROM public.stripe_webhook_events AS old
      WHERE old.received_at < now() - INTERVAL '90 days'
      ORDER BY old.received_at
      LIMIT 1000
   );

  RETURN COALESCE(v_applied, FALSE);
END;
$$;

REVOKE ALL ON FUNCTION public.apply_stripe_subscription_event(
  TEXT, BIGINT, TEXT, TEXT, UUID, TEXT, TEXT, TEXT, TEXT,
  TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_stripe_subscription_event(
  TEXT, BIGINT, TEXT, TEXT, UUID, TEXT, TEXT, TEXT, TEXT,
  TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ
) TO service_role;

-- Define operational lease storage before the SQL-language health function
-- references it. PostgreSQL resolves relation references when a LANGUAGE sql
-- function is created, not only when it is first called.
CREATE TABLE IF NOT EXISTS public.media_scan_jobs (
  kind TEXT NOT NULL CHECK (kind IN ('post', 'whisper')),
  content_id UUID NOT NULL,
  user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  lease_id UUID NOT NULL,
  attempts INT NOT NULL DEFAULT 1 CHECK (attempts BETWEEN 1 AND 20),
  lease_expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  PRIMARY KEY (kind, content_id)
);
CREATE INDEX IF NOT EXISTS media_scan_jobs_user_created_idx
  ON public.media_scan_jobs (user_id, created_at DESC);
ALTER TABLE public.media_scan_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.media_scan_jobs FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.media_scan_jobs TO service_role;

-- Aggregate operational health only: no user ids, authored content, object
-- paths, push tokens, or recovery data. A monitor can alert on user-impacting
-- backlog while the service role remains the only caller.
CREATE OR REPLACE FUNCTION public.trust_boundary_health()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'push_queued', (
      SELECT count(*) FROM public.push_delivery_outbox WHERE status = 'queued'
    ),
    'push_processing', (
      SELECT count(*) FROM public.push_delivery_outbox WHERE status = 'processing'
    ),
    'push_dead_24h', (
      SELECT count(*) FROM public.push_delivery_outbox
       WHERE status = 'dead' AND created_at > now() - INTERVAL '24 hours'
    ),
    'email_queued', (
      SELECT count(*) FROM public.email_outbox WHERE status = 'queued'
    ),
    'email_failed_24h', (
      SELECT count(*) FROM public.email_outbox
       WHERE status = 'failed' AND created_at > now() - INTERVAL '24 hours'
    ),
    'oldest_email_age_seconds', COALESCE((
      SELECT EXTRACT(EPOCH FROM now() - min(created_at))::BIGINT
        FROM public.email_outbox
       WHERE status IN ('queued', 'sending')
    ), 0),
    'oldest_push_age_seconds', COALESCE((
      SELECT EXTRACT(EPOCH FROM now() - min(created_at))::BIGINT
        FROM public.push_delivery_outbox
       WHERE status IN ('queued', 'processing')
    ), 0),
    'stale_pending_media', (
      (SELECT count(*) FROM public.posts
        WHERE media_status = 'pending' AND created_at < now() - INTERVAL '15 minutes')
      +
      (SELECT count(*) FROM public.whispers
        WHERE media_status = 'pending' AND created_at < now() - INTERVAL '15 minutes')
    ),
    'active_media_scan_leases', (
      SELECT count(*) FROM public.media_scan_jobs
       WHERE completed_at IS NULL AND lease_expires_at > now()
    ),
    'active_accounts_needing_age', (
      SELECT count(*) FROM public.users
       WHERE account_status = 'active' AND birth_year IS NULL
    ),
    'measured_at', now()
  );
$$;

REVOKE ALL ON FUNCTION public.trust_boundary_health()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.trust_boundary_health() TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Space summaries may see aggregate moods, never vent bodies.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.collect_space_mood_counts(p_space_id UUID)
RETURNS TABLE (post_mood TEXT, vent_count INT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT post.post_mood::TEXT, count(*)::INT
    FROM public.posts AS post
   WHERE post.space_id = p_space_id
     AND post.deleted_at IS NULL
     AND post.created_at > now() - INTERVAL '24 hours'
   GROUP BY post.post_mood
   ORDER BY count(*) DESC, post.post_mood::TEXT;
$$;

REVOKE ALL ON FUNCTION public.collect_space_vent_corpus(UUID, INT)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.collect_space_mood_counts(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.collect_space_mood_counts(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.pick_spaces_for_summary(INT) TO service_role;

-- A user can ask to scan only their canonical pending image. Per-resource
-- leases prevent concurrent provider calls for the same upload, and the shared
-- server quota bounds paid moderation traffic from one account.
CREATE OR REPLACE FUNCTION public.claim_media_scan(
  p_kind TEXT,
  p_content_id UUID,
  p_user_id UUID,
  p_lease_id UUID
) RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_claimed UUID;
BEGIN
  IF p_kind NOT IN ('post', 'whisper')
     OR p_content_id IS NULL OR p_user_id IS NULL OR p_lease_id IS NULL
  THEN
    RETURN 'invalid';
  END IF;
  IF p_kind = 'post' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.posts AS post
       WHERE post.post_id = p_content_id
         AND post.author_id = p_user_id
         AND post.media_status = 'pending'
    ) THEN RETURN 'invalid'; END IF;
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM public.whispers AS whisper
       WHERE whisper.whisper_id = p_content_id
         AND whisper.author_id = p_user_id
         AND whisper.media_status = 'pending'
    ) THEN RETURN 'invalid'; END IF;
  END IF;

  IF NOT public.consume_moderation_quota(p_user_id) THEN
    RETURN 'rate_limited';
  END IF;

  INSERT INTO public.media_scan_jobs (
    kind, content_id, user_id, lease_id, lease_expires_at
  ) VALUES (
    p_kind, p_content_id, p_user_id, p_lease_id,
    now() + INTERVAL '2 minutes'
  )
  ON CONFLICT (kind, content_id) DO UPDATE
     SET lease_id = EXCLUDED.lease_id,
         lease_expires_at = EXCLUDED.lease_expires_at,
         attempts = media_scan_jobs.attempts + 1
   WHERE media_scan_jobs.user_id = EXCLUDED.user_id
     AND media_scan_jobs.completed_at IS NULL
     AND media_scan_jobs.lease_expires_at < now()
     AND media_scan_jobs.attempts < 8
  RETURNING lease_id INTO v_claimed;

  DELETE FROM public.media_scan_jobs AS job
   WHERE job.completed_at < now() - INTERVAL '7 days'
     AND job.content_id IN (
       SELECT old.content_id FROM public.media_scan_jobs AS old
        WHERE old.completed_at < now() - INTERVAL '7 days'
        ORDER BY old.completed_at
        LIMIT 500
     );
  RETURN CASE WHEN v_claimed IS NULL THEN 'busy' ELSE 'claimed' END;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_media_scan_verdict(
  p_kind TEXT,
  p_content_id UUID,
  p_user_id UUID,
  p_lease_id UUID,
  p_verdict TEXT,
  p_labels JSONB
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_applied BOOLEAN := FALSE;
BEGIN
  IF p_verdict NOT IN ('clean', 'sensitive', 'blocked')
     OR octet_length(COALESCE(p_labels, '{}'::JSONB)::TEXT) > 4096
  THEN
    RAISE EXCEPTION 'invalid_media_verdict';
  END IF;
  -- Serialize completion with a retry attempting to replace an expired lease.
  -- Once this row is locked, either this lease commits its verdict or the retry
  -- observes the completed job and cannot acquire it.
  PERFORM 1 FROM public.media_scan_jobs AS job
   WHERE job.kind = p_kind
     AND job.content_id = p_content_id
     AND job.user_id = p_user_id
     AND job.lease_id = p_lease_id
     AND job.completed_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN RETURN FALSE; END IF;

  IF p_kind = 'post' THEN
    UPDATE public.posts AS post
       SET media_status = p_verdict,
           media_labels = COALESCE(p_labels, '{}'::JSONB)
     WHERE post.post_id = p_content_id
       AND post.author_id = p_user_id
       AND post.media_status = 'pending';
  ELSIF p_kind = 'whisper' THEN
    UPDATE public.whispers AS whisper
       SET media_status = p_verdict,
           media_labels = COALESCE(p_labels, '{}'::JSONB)
     WHERE whisper.whisper_id = p_content_id
       AND whisper.author_id = p_user_id
       AND whisper.media_status = 'pending';
  ELSE
    RAISE EXCEPTION 'invalid_media_kind';
  END IF;
  v_applied := FOUND;

  UPDATE public.media_scan_jobs AS job
     SET completed_at = now(), lease_expires_at = now()
   WHERE job.kind = p_kind
     AND job.content_id = p_content_id
     AND job.lease_id = p_lease_id;
  RETURN v_applied;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_claimed_csam_incident(
  p_kind TEXT,
  p_content_id UUID,
  p_user_id UUID,
  p_lease_id UUID,
  p_labels JSONB
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_incident UUID;
BEGIN
  -- Hold the lease row while quarantining so a retry cannot replace the lease
  -- between validation and the incident transaction.
  PERFORM 1 FROM public.media_scan_jobs AS job
   WHERE job.kind = p_kind
     AND job.content_id = p_content_id
     AND job.user_id = p_user_id
     AND job.lease_id = p_lease_id
     AND job.completed_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;

  IF p_kind = 'post' THEN
    PERFORM 1 FROM public.posts AS post
     WHERE post.post_id = p_content_id
       AND post.author_id = p_user_id
       AND post.media_status = 'pending'
     FOR UPDATE;
  ELSIF p_kind = 'whisper' THEN
    PERFORM 1 FROM public.whispers AS whisper
     WHERE whisper.whisper_id = p_content_id
       AND whisper.author_id = p_user_id
       AND whisper.media_status = 'pending'
     FOR UPDATE;
  ELSE
    RAISE EXCEPTION 'invalid_media_kind';
  END IF;
  IF NOT FOUND THEN
    UPDATE public.media_scan_jobs AS job
       SET completed_at = now(), lease_expires_at = now()
     WHERE job.kind = p_kind
       AND job.content_id = p_content_id
       AND job.lease_id = p_lease_id;
    RETURN NULL;
  END IF;

  v_incident := public.record_csam_incident(
    p_kind, p_content_id, NULL, p_user_id, p_labels
  );
  UPDATE public.media_scan_jobs AS job
     SET completed_at = now(), lease_expires_at = now()
   WHERE job.kind = p_kind
     AND job.content_id = p_content_id
     AND job.lease_id = p_lease_id;
  RETURN v_incident;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_media_scan(TEXT, UUID, UUID, UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_media_scan_verdict(
  TEXT, UUID, UUID, UUID, TEXT, JSONB
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_claimed_csam_incident(
  TEXT, UUID, UUID, UUID, JSONB
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_media_scan(TEXT, UUID, UUID, UUID)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_media_scan_verdict(
  TEXT, UUID, UUID, UUID, TEXT, JSONB
) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_claimed_csam_incident(
  TEXT, UUID, UUID, UUID, JSONB
) TO service_role;

-- Storage cleanup must query storage.objects directly: bucket list APIs are
-- directory-oriented and a root-page sweep silently misses user-id folders.
-- This bounded RPC finds the globally oldest unreferenced objects without
-- exposing object names to clients.
CREATE OR REPLACE FUNCTION public.list_storage_cleanup_candidates(
  p_limit INT DEFAULT 250
) RETURNS TABLE (bucket_id TEXT, object_name TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT object.bucket_id::TEXT, object.name::TEXT
    FROM storage.objects AS object
   WHERE object.bucket_id IN (
     'profile-photos', 'post-media', 'tribe-chat-media',
     'chat-media', 'whispers-media'
   )
     AND object.created_at < now() - INTERVAL '7 days'
     AND CASE object.bucket_id
       WHEN 'profile-photos' THEN NOT EXISTS (
         SELECT 1 FROM public.users AS app_user
          WHERE app_user.profile_photo_path = object.name
       )
       WHEN 'post-media' THEN NOT EXISTS (
         SELECT 1 FROM public.posts AS post
          WHERE post.image_path = object.name OR post.audio_path = object.name
       )
       WHEN 'tribe-chat-media' THEN NOT EXISTS (
         SELECT 1 FROM public.tribe_messages AS message
          WHERE message.image_path = object.name OR message.audio_path = object.name
       )
       WHEN 'chat-media' THEN NOT EXISTS (
         SELECT 1 FROM public.chat_messages AS message
          WHERE message.attached_media_path = object.name
       )
       WHEN 'whispers-media' THEN NOT EXISTS (
         SELECT 1 FROM public.whispers AS whisper
          WHERE whisper.audio_path = object.name
             OR split_part(
               COALESCE(whisper.background_image_url, ''),
               '/whispers-media/',
               2
             ) = object.name
       )
       ELSE FALSE
     END
   ORDER BY object.created_at, object.id
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 250), 1), 500);
$$;

REVOKE ALL ON FUNCTION public.list_storage_cleanup_candidates(INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_storage_cleanup_candidates(INT)
  TO service_role;

-- Bind CSAM quarantine to the canonical content row as a second line of
-- defence. Historical parameters remain for API compatibility but caller-
-- supplied author and URL values are deliberately ignored. Concurrent scans
-- serialize per resource and reuse an existing open incident.
CREATE OR REPLACE FUNCTION public.record_csam_incident(
  p_kind TEXT,
  p_id UUID,
  p_media_url TEXT,
  p_author UUID,
  p_labels JSONB DEFAULT '{}'::JSONB
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_incident UUID;
  v_author UUID;
  v_media_url TEXT;
BEGIN
  IF p_kind NOT IN ('post', 'whisper') OR p_id IS NULL THEN
    RAISE EXCEPTION 'invalid_content_reference';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_kind || ':' || p_id::TEXT, 0)
  );

  IF p_kind = 'post' THEN
    SELECT post.author_id, post.image_url
      INTO v_author, v_media_url
      FROM public.posts AS post
     WHERE post.post_id = p_id AND post.media_status = 'pending';
  ELSE
    SELECT whisper.author_id, whisper.background_image_url
      INTO v_author, v_media_url
      FROM public.whispers AS whisper
     WHERE whisper.whisper_id = p_id AND whisper.media_status = 'pending';
  END IF;
  IF NOT FOUND OR v_author IS NULL OR v_media_url IS NULL THEN
    RAISE EXCEPTION 'pending_media_not_found';
  END IF;

  SELECT incident.incident_id
    INTO v_incident
    FROM public.csam_incidents AS incident
   WHERE incident.kind = p_kind
     AND incident.content_ref = p_id
     AND incident.status = 'detected'
   ORDER BY incident.detected_at DESC
   LIMIT 1;
  IF FOUND THEN RETURN v_incident; END IF;

  IF p_kind = 'post' THEN
    UPDATE public.posts SET media_status = 'blocked' WHERE post_id = p_id;
  ELSE
    UPDATE public.whispers SET media_status = 'blocked' WHERE whisper_id = p_id;
  END IF;

  INSERT INTO public.csam_incidents (
    kind, content_ref, media_url, author_id, labels
  ) VALUES (
    p_kind, p_id, v_media_url, v_author,
    jsonb_build_object('csam', COALESCE(p_labels->'csam', 'null'::JSONB))
  ) RETURNING incident_id INTO v_incident;

  PERFORM public.admin_log(
    'csam.detected', 'csam_incident', v_incident, NULL, NULL,
    jsonb_build_object('kind', p_kind, 'content_ref', p_id),
    'Auto-detected — requires mandated review/report',
    '{}'::JSONB
  );
  RETURN v_incident;
END;
$$;

REVOKE ALL ON FUNCTION public.record_csam_incident(
  TEXT, UUID, TEXT, UUID, JSONB
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_csam_incident(
  TEXT, UUID, TEXT, UUID, JSONB
) TO service_role;

-- The Edge worker checks legal holds before deletion, but a database trigger
-- closes the race where an incident opens between that lookup and the final
-- public.users delete. Preserving evidence wins over completing the purge.
CREATE OR REPLACE FUNCTION private.prevent_legal_hold_user_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.csam_incidents AS incident
     WHERE incident.author_id = OLD.user_id
       AND incident.status IN ('detected', 'reported')
  ) THEN
    RAISE EXCEPTION 'legal_hold_active' USING ERRCODE = 'P0001';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS prevent_legal_hold_user_delete ON public.users;
CREATE TRIGGER prevent_legal_hold_user_delete
  BEFORE DELETE ON public.users
  FOR EACH ROW EXECUTE FUNCTION private.prevent_legal_hold_user_delete();

REVOKE ALL ON FUNCTION private.prevent_legal_hold_user_delete()
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Server-owned text safety. Self-harm language is tagged for support and is
--    never blocked; doxxing/contact details, targeted harassment, hate terms,
--    sexual solicitation, and active staff block rules are rejected.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.contains_phone_number(p_text TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_match TEXT[];
  v_candidate TEXT;
  v_digits TEXT;
BEGIN
  FOR v_match IN
    SELECT regexp_matches(
      COALESCE(p_text, ''),
      '(\+?[0-9]([[:space:]-]?[0-9]){6,14})',
      'g'
    )
  LOOP
    v_candidate := v_match[1];
    v_digits := regexp_replace(v_candidate, '[^0-9]', '', 'g');
    IF v_digits ~ '^(19|20)[0-9]{6}$' THEN CONTINUE; END IF;
    IF length(v_digits) >= 9
       OR (length(v_digits) >= 7 AND (v_candidate LIKE '+%' OR v_candidate ~ '[[:space:]-]'))
    THEN
      RETURN TRUE;
    END IF;
  END LOOP;
  RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION private.server_text_safety(p_text TEXT)
RETURNS TABLE (clean_text TEXT, crisis_level TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_lower TEXT;
  v_rule RECORD;
  v_matches BOOLEAN;
BEGIN
  clean_text := public.sanitize_user_text(p_text);
  v_lower := lower(COALESCE(clean_text, ''));
  crisis_level := NULL;

  IF private.contains_phone_number(clean_text)
     OR clean_text ~* '[[:alnum:]_.%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'
  THEN
    RAISE EXCEPTION 'content_blocked_privacy' USING ERRCODE = 'P0001';
  END IF;

  IF v_lower LIKE ANY (ARRAY[
    '%kill yourself%', '%go die%', '%nobody loves you%', '%you should die%'
  ]) OR v_lower ~ '(^|[^a-z])kys([^a-z]|$)' THEN
    RAISE EXCEPTION 'content_blocked_harassment' USING ERRCODE = 'P0001';
  END IF;
  IF v_lower ~ '(^|[^a-z])(retard|faggot)([^a-z]|$)'
     OR v_lower LIKE '%n word%'
  THEN
    RAISE EXCEPTION 'content_blocked_hate' USING ERRCODE = 'P0001';
  END IF;
  IF v_lower LIKE ANY (ARRAY['%nude pic%', '%send nudes%']) THEN
    RAISE EXCEPTION 'content_blocked_sexual_solicitation' USING ERRCODE = 'P0001';
  END IF;

  IF v_lower LIKE ANY (ARRAY[
    '%kill myself%', '%end it all%', '%suicide%', '%i want to die%',
    '%cutting myself%', '%overdose%', '%jump off%',
    '%no reason to live%'
  ]) OR v_lower ~ '(^|[^a-z])kms([^a-z]|$)' THEN
    crisis_level := 'high';
  ELSIF v_lower LIKE ANY (ARRAY['%self harm%', '%won''t be here%']) THEN
    crisis_level := 'elevated';
  END IF;

  FOR v_rule IN
    SELECT rule.pattern, rule.match_type, rule.action
     FROM public.automod_rules AS rule
     WHERE rule.is_active
       AND btrim(rule.pattern) <> ''
       AND rule.match_type IN ('contains', 'word')
  LOOP
    -- Staff input is data, never executable regex, in the authoritative path.
    -- Regex rules remain an advisory client/Tier-2 feature until they can run
    -- in an engine with explicit time and complexity limits.
    v_matches := CASE v_rule.match_type
      WHEN 'word' THEN
        position(
          ' ' || lower(btrim(v_rule.pattern)) || ' '
          IN ' ' || regexp_replace(v_lower, '[^[:alnum:]_]+', ' ', 'g') || ' '
        ) > 0
      ELSE position(lower(btrim(v_rule.pattern)) IN v_lower) > 0
    END;

    IF v_matches AND v_rule.action = 'block' THEN
      RAISE EXCEPTION 'content_blocked_automod' USING ERRCODE = 'P0001';
    ELSIF v_matches AND v_rule.action = 'crisis' THEN
      crisis_level := COALESCE(crisis_level, 'elevated');
    END IF;
  END LOOP;

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION private.contains_phone_number(TEXT)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.server_text_safety(TEXT)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.assert_user_can_write(p_user UUID)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user RECORD;
  v_age INT;
BEGIN
  SELECT user_row.account_status, user_row.birth_year
    INTO v_user
    FROM public.users AS user_row
   WHERE user_row.user_id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'account_not_found'; END IF;
  IF v_user.account_status <> 'active' THEN RAISE EXCEPTION 'account_not_active'; END IF;
  IF v_user.birth_year IS NULL THEN
    RAISE EXCEPTION 'age_verification_required' USING ERRCODE = 'P0001';
  END IF;
  v_age := EXTRACT(YEAR FROM now())::INT - v_user.birth_year;
  IF v_age < 13 THEN RAISE EXCEPTION 'age_below_minimum' USING ERRCODE = 'P0001'; END IF;
END;
$$;

REVOKE ALL ON FUNCTION private.assert_user_can_write(UUID)
  FROM PUBLIC, anon, authenticated;

-- Preserve the existing rate-limit contract while adding the non-bypassable
-- account/age prerequisite shared by every guarded write.
CREATE OR REPLACE FUNCTION public._writer_state(p_user UUID)
RETURNS TABLE (account_age INTERVAL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_cooldown TIMESTAMPTZ;
  v_created TIMESTAMPTZ;
BEGIN
  PERFORM private.assert_user_can_write(p_user);
  SELECT users.posting_cooldown_until, users.created_at
    INTO v_cooldown, v_created
    FROM public.users WHERE users.user_id = p_user;
  IF v_cooldown IS NOT NULL AND v_cooldown > now() THEN
    RAISE EXCEPTION 'Posting is paused on your account for a little while.'
      USING ERRCODE = 'P0001';
  END IF;
  RETURN QUERY SELECT now() - COALESCE(v_created, now());
END;
$$;

CREATE OR REPLACE FUNCTION public._server_content_write_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_safety RECORD;
  v_text TEXT;
BEGIN
  IF TG_TABLE_NAME = 'posts' THEN
    PERFORM private.assert_user_can_write(NEW.author_id);
    SELECT * INTO v_safety FROM private.server_text_safety(NEW.content);
    NEW.content := COALESCE(v_safety.clean_text, '');
    NEW.crisis_level := COALESCE(NEW.crisis_level, v_safety.crisis_level);
  ELSIF TG_TABLE_NAME IN ('posts_comments', 'whisper_comments') THEN
    PERFORM private.assert_user_can_write(NEW.author_id);
    SELECT * INTO v_safety FROM private.server_text_safety(NEW.content);
    NEW.content := COALESCE(v_safety.clean_text, '');
  ELSIF TG_TABLE_NAME = 'tribe_messages' THEN
    PERFORM private.assert_user_can_write(NEW.sender_id);
    SELECT * INTO v_safety FROM private.server_text_safety(NEW.content);
    NEW.content := v_safety.clean_text;
    NEW.crisis_level := COALESCE(NEW.crisis_level, v_safety.crisis_level);
  ELSIF TG_TABLE_NAME = 'chat_messages' THEN
    PERFORM private.assert_user_can_write(NEW.sender_id);
    SELECT * INTO v_safety FROM private.server_text_safety(NEW.encrypted_payload);
    -- Historical column name; the current product stores server-readable
    -- plaintext for abuse review and must never label this value as E2EE.
    NEW.encrypted_payload := COALESCE(v_safety.clean_text, '');
    NEW.crisis_level := COALESCE(NEW.crisis_level, v_safety.crisis_level);
  ELSIF TG_TABLE_NAME = 'whispers' THEN
    PERFORM private.assert_user_can_write(NEW.author_id);
    v_text := concat_ws(' ', NEW.title, NEW.description);
    SELECT * INTO v_safety FROM private.server_text_safety(v_text);
    NEW.title := public.sanitize_user_text(NEW.title);
    NEW.description := public.sanitize_user_text(NEW.description);
    NEW.crisis_level := COALESCE(NEW.crisis_level, v_safety.crisis_level);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS content_safety_guard_posts ON public.posts;
CREATE TRIGGER content_safety_guard_posts
  BEFORE INSERT OR UPDATE OF content ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public._server_content_write_guard();
DROP TRIGGER IF EXISTS content_safety_guard_post_comments ON public.posts_comments;
CREATE TRIGGER content_safety_guard_post_comments
  BEFORE INSERT OR UPDATE OF content ON public.posts_comments
  FOR EACH ROW EXECUTE FUNCTION public._server_content_write_guard();
DROP TRIGGER IF EXISTS content_safety_guard_whisper_comments ON public.whisper_comments;
CREATE TRIGGER content_safety_guard_whisper_comments
  BEFORE INSERT OR UPDATE OF content ON public.whisper_comments
  FOR EACH ROW EXECUTE FUNCTION public._server_content_write_guard();
DROP TRIGGER IF EXISTS content_safety_guard_tribe_messages ON public.tribe_messages;
CREATE TRIGGER content_safety_guard_tribe_messages
  BEFORE INSERT OR UPDATE OF content ON public.tribe_messages
  FOR EACH ROW EXECUTE FUNCTION public._server_content_write_guard();
DROP TRIGGER IF EXISTS content_safety_guard_chat_messages ON public.chat_messages;
CREATE TRIGGER content_safety_guard_chat_messages
  BEFORE INSERT OR UPDATE OF encrypted_payload ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION public._server_content_write_guard();
DROP TRIGGER IF EXISTS content_safety_guard_whispers ON public.whispers;
CREATE TRIGGER content_safety_guard_whispers
  BEFORE INSERT OR UPDATE OF title, description ON public.whispers
  FOR EACH ROW EXECUTE FUNCTION public._server_content_write_guard();

REVOKE ALL ON FUNCTION public._server_content_write_guard()
  FROM PUBLIC, anon, authenticated;

-- Keep the staff safety queue truthful as well. The current DM schema is
-- server-readable for abuse review; the staff-only RPC deliberately returns a
-- restricted placeholder instead of making an unsupported encryption claim.
CREATE OR REPLACE FUNCTION public.admin_safety_queue(
  p_include_resolved BOOLEAN DEFAULT FALSE,
  p_limit INT DEFAULT 200
) RETURNS TABLE (
  item_type TEXT,
  severity TEXT,
  severity_rank INT,
  ref_id UUID,
  report_id UUID,
  reason TEXT,
  note TEXT,
  author_id UUID,
  author_pseudonym TEXT,
  preview TEXT,
  is_open BOOLEAN,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_staff(
    auth.uid(), ARRAY['super_admin', 'admin', 'moderator', 'support']
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN QUERY
  WITH items (
    item_type, severity, severity_rank, ref_id, report_id, reason, note,
    author_id, author_pseudonym, preview, is_open, created_at
  ) AS (
    SELECT 'crisis_post'::TEXT,
           post.crisis_level::TEXT,
           CASE post.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           post.post_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           post.author_id, app_user.anonymous_pseudonym::TEXT,
           left(COALESCE(post.content, ''), 200)::TEXT,
           post.deleted_at IS NULL, post.created_at
      FROM public.posts AS post
      LEFT JOIN public.users AS app_user ON app_user.user_id = post.author_id
     WHERE post.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'crisis_whisper'::TEXT,
           whisper.crisis_level::TEXT,
           CASE whisper.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           whisper.whisper_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           whisper.author_id, app_user.anonymous_pseudonym::TEXT,
           left(
             COALESCE(whisper.title, whisper.description, 'Voice whisper'), 200
           )::TEXT,
           whisper.deleted_at IS NULL, whisper.created_at
      FROM public.whispers AS whisper
      LEFT JOIN public.users AS app_user
        ON app_user.user_id = whisper.author_id
     WHERE whisper.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'crisis_tribe_message'::TEXT,
           message.crisis_level::TEXT,
           CASE message.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           message.message_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           message.sender_id, app_user.anonymous_pseudonym::TEXT,
           left(COALESCE(message.content, ''), 200)::TEXT,
           message.deleted_at IS NULL, message.created_at
      FROM public.tribe_messages AS message
      LEFT JOIN public.users AS app_user
        ON app_user.user_id = message.sender_id
     WHERE message.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'crisis_dm'::TEXT,
           message.crisis_level::TEXT,
           CASE message.crisis_level WHEN 'high' THEN 3 ELSE 2 END,
           message.message_id, NULL::UUID, NULL::TEXT, NULL::TEXT,
           message.sender_id, app_user.anonymous_pseudonym::TEXT,
           '(private DM - server-readable; access restricted)'::TEXT,
           TRUE, message.created_at
      FROM public.chat_messages AS message
      LEFT JOIN public.users AS app_user
        ON app_user.user_id = message.sender_id
     WHERE message.crisis_level IS NOT NULL

    UNION ALL
    SELECT 'self_harm_report'::TEXT,
           'high'::TEXT,
           3,
           report.report_id,
           report.report_id,
           report.reason::TEXT,
           report.note::TEXT,
           COALESCE(post.author_id, tribe_message.sender_id, dm.sender_id),
           COALESCE(
             post_user.anonymous_pseudonym,
             tribe_user.anonymous_pseudonym,
             dm_user.anonymous_pseudonym
           )::TEXT,
           COALESCE(
             left(post.content, 200),
             left(tribe_message.content, 200),
             CASE WHEN report.target_chat_message_id IS NOT NULL
               THEN '(private DM - server-readable; access restricted)' END,
             CASE WHEN report.target_comment_id IS NOT NULL
               THEN '(reported comment)' END,
             CASE WHEN report.target_room_id IS NOT NULL
               THEN '(reported conversation)' END,
             '(reported content)'
           )::TEXT,
           NOT report.is_resolved,
           report.created_at
      FROM public.reports AS report
      LEFT JOIN public.posts AS post ON post.post_id = report.post_id
      LEFT JOIN public.users AS post_user
        ON post_user.user_id = post.author_id
      LEFT JOIN public.tribe_messages AS tribe_message
        ON tribe_message.message_id = report.target_tribe_message_id
      LEFT JOIN public.users AS tribe_user
        ON tribe_user.user_id = tribe_message.sender_id
      LEFT JOIN public.chat_messages AS dm
        ON dm.message_id = report.target_chat_message_id
      LEFT JOIN public.users AS dm_user ON dm_user.user_id = dm.sender_id
     WHERE report.reason = 'self_harm'
  )
  SELECT item.*
    FROM items AS item
   WHERE p_include_resolved OR item.is_open
   ORDER BY item.is_open DESC, item.severity_rank DESC, item.created_at DESC
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 200), 1000));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_safety_queue(BOOLEAN, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_safety_queue(BOOLEAN, INT)
  TO authenticated;

CREATE OR REPLACE FUNCTION public._whispers_write_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_account_age INTERVAL;
  v_hour BIGINT;
BEGIN
  IF NEW.author_id IS NULL THEN RAISE EXCEPTION 'author_required'; END IF;
  SELECT account_age INTO v_account_age FROM public._writer_state(NEW.author_id);
  SELECT count(*) INTO v_hour
    FROM public.whispers AS whisper
   WHERE whisper.author_id = NEW.author_id
     AND whisper.created_at > now() - INTERVAL '1 hour';
  PERFORM public._guard_write(
    NEW.author_id, 'whispers', v_hour, 10, 'hour'
  );
  IF v_account_age < INTERVAL '1 hour' THEN
    PERFORM public._guard_write(
      NEW.author_id, 'whispers from a new account', v_hour, 3, 'hour'
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS whispers_write_guard ON public.whispers;
CREATE TRIGGER whispers_write_guard
  BEFORE INSERT ON public.whispers
  FOR EACH ROW EXECUTE FUNCTION public._whispers_write_guard();

REVOKE ALL ON FUNCTION public._whispers_write_guard()
  FROM PUBLIC, anon, authenticated;

-- Whispers previously lacked a retry-stable mutation receipt. Extend the
-- existing exactly-once ledger and wrap the canonical create_whisper RPC.
ALTER TABLE private.client_mutation_receipts
  DROP CONSTRAINT IF EXISTS client_mutation_receipts_operation_kind_check;
ALTER TABLE private.client_mutation_receipts
  ADD CONSTRAINT client_mutation_receipts_operation_kind_check
  CHECK (operation_kind IN (
    'post', 'comment', 'whisper_comment', 'dm', 'tribe_message', 'whisper'
  ));

CREATE OR REPLACE FUNCTION public.create_whisper_idempotent(
  p_mutation_id UUID,
  p_audio_path TEXT,
  p_audio_url TEXT,
  p_audio_duration_seconds INT,
  p_category_name TEXT,
  p_background_image_url TEXT DEFAULT NULL,
  p_voice_filter TEXT DEFAULT 'none',
  p_title TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_persona_id UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_resource_id UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF p_mutation_id IS NULL THEN RAISE EXCEPTION 'mutation id required'; END IF;
  v_resource_id := private.existing_client_mutation(
    v_me, p_mutation_id, 'whisper'
  );
  IF v_resource_id IS NOT NULL THEN RETURN v_resource_id; END IF;

  v_resource_id := public.create_whisper(
    p_audio_path,
    p_audio_url,
    p_audio_duration_seconds,
    p_category_name,
    p_background_image_url,
    p_voice_filter,
    p_title,
    p_description,
    p_persona_id
  );
  PERFORM private.complete_client_mutation(
    v_me, p_mutation_id, 'whisper', v_resource_id
  );
  RETURN v_resource_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_whisper_idempotent(
  UUID, TEXT, TEXT, INT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_whisper_idempotent(
  UUID, TEXT, TEXT, INT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID
) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Recovery material rotates with password changes. Only the account owner
--    may fetch/replace its sealed blob; clients can roll the auth password back
--    if the second cross-service step fails.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_recovery_material()
RETURNS TABLE (recovery_blob TEXT, recovery_salt TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT users.recovery_blob, users.recovery_salt
    FROM public.users AS users
   WHERE users.user_id = (SELECT auth.uid());
$$;

CREATE OR REPLACE FUNCTION public.rotate_my_recovery_material(
  p_recovery_blob TEXT,
  p_recovery_salt TEXT
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF length(COALESCE(p_recovery_blob, '')) NOT BETWEEN 40 AND 2000
     OR length(COALESCE(p_recovery_salt, '')) NOT BETWEEN 16 AND 200
  THEN
    RAISE EXCEPTION 'invalid_recovery_material';
  END IF;
  UPDATE public.users
     SET recovery_blob = p_recovery_blob,
         recovery_salt = p_recovery_salt,
         updated_at = now()
   WHERE user_id = (SELECT auth.uid())
     AND recovery_blob IS NOT NULL
     AND recovery_salt IS NOT NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'recovery_material_not_found'; END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_recovery_material() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rotate_my_recovery_material(TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_recovery_material() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rotate_my_recovery_material(TEXT, TEXT)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Truthful DSAR: chats are server-readable plaintext and their bodies are
--    therefore included in the requesting sender's export.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.export_my_data()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_me UUID := auth.uid(); v_out JSONB;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT jsonb_build_object(
    'exported_at', now(),
    'format', 'venttly-dsar-v2',
    'account', (
      SELECT to_jsonb(u) - ARRAY[
        'recovery_blob', 'recovery_salt', 'recovery_key_hash',
        'device_signature_hash', 'public_key'
      ] FROM public.users AS u WHERE u.user_id = v_me
    ),
    'posts', (
      SELECT COALESCE(jsonb_agg(to_jsonb(p) - 'author_id'), '[]'::JSONB)
        FROM public.posts AS p WHERE p.author_id = v_me
    ),
    'comments', (
      SELECT COALESCE(jsonb_agg(to_jsonb(c) - 'author_id'), '[]'::JSONB)
        FROM public.posts_comments AS c WHERE c.author_id = v_me
    ),
    'whispers', (
      SELECT COALESCE(jsonb_agg(to_jsonb(w) - 'author_id'), '[]'::JSONB)
        FROM public.whispers AS w WHERE w.author_id = v_me
    ),
    'tribe_messages', (
      SELECT COALESCE(jsonb_agg(to_jsonb(m) - 'sender_id'), '[]'::JSONB)
        FROM public.tribe_messages AS m WHERE m.sender_id = v_me
    ),
    'direct_messages', (
      SELECT COALESCE(jsonb_agg(
        (to_jsonb(m) - 'sender_id' - 'encrypted_payload') ||
        jsonb_build_object('body', m.encrypted_payload)
      ), '[]'::JSONB)
        FROM public.chat_messages AS m WHERE m.sender_id = v_me
    ),
    'reactions', (
      SELECT COALESCE(jsonb_agg(to_jsonb(r) - 'user_id'), '[]'::JSONB)
        FROM public.post_likes AS r WHERE r.user_id = v_me
    ),
    'reports_filed', (
      SELECT COALESCE(jsonb_agg(to_jsonb(r) - 'reporter_id'), '[]'::JSONB)
        FROM public.reports AS r WHERE r.reporter_id = v_me
    ),
    'tribe_memberships', (
      SELECT COALESCE(jsonb_agg(to_jsonb(m) - 'user_id'), '[]'::JSONB)
        FROM public.tribe_members AS m WHERE m.user_id = v_me
    )
  ) INTO v_out;
  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION public.export_my_data() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.export_my_data() TO authenticated;

NOTIFY pgrst, 'reload schema';
