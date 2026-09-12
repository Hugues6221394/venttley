-- Login risk scoring, security alerts, and the "was this you?" loop.
--
-- 20260828230000 gave Venttly a device and a session it could see. It could
-- not yet form an opinion about them. A sign-in from a brand new handset in a
-- country the account has never touched, minutes after a burst of failed
-- password guesses, was recorded exactly like the user unlocking their own
-- phone on the sofa. This migration is the opinion.
--
-- What lands here:
--
--   security_risk_weights   the scoring policy as data, not as code. Retuning
--                           the engine after launch is an UPDATE, not a
--                           deploy — which matters because the right weights
--                           are unknowable until real traffic exists.
--   evaluate_login_risk()   turns four cheap signals into a score. Runs only
--                           when a session row is actually opened, so a cold
--                           start does not re-score a sign-in that already
--                           happened.
--   raise_security_alert()  the producer the security_alert email template has
--                           been waiting for since 0046. Writes the in-app
--                           notification and queues the mail together, so the
--                           two can never disagree about what happened.
--   resolve_suspicious_login()  one RPC, one decision. "Yes, that was me"
--                           trusts the device; "no" blocks it and ends every
--                           session on it.
--
-- On thresholds: alerting is deliberately cheaper than challenging. Telling
-- someone what happened costs them a glance. Asking them to adjudicate costs
-- them a decision, and a security prompt that cries wolf is worse than no
-- prompt at all — users learn to dismiss it, and then it is decoration.
--
-- On what is NOT scored: no IP address, no user agent, no precise location.
-- Country comes from the CDN edge via geo-capture and nothing finer exists.
-- A risk engine is a surveillance engine pointed the other way, and the only
-- durable protection against it being repurposed is not collecting the data.

-- ============================================================
-- 1. The scoring policy, as data
-- ============================================================
CREATE TABLE IF NOT EXISTS public.security_risk_weights (
  signal      TEXT PRIMARY KEY,
  weight      INT  NOT NULL CHECK (weight BETWEEN 0 AND 200),
  description TEXT NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.security_risk_weights IS
  'Login risk weights and thresholds. Operator-tunable at runtime; seeded once and never overwritten by re-running this migration.';

-- ON CONFLICT DO NOTHING, not DO UPDATE: once an operator has tuned a weight
-- against real traffic, a redeploy must not quietly reset it to the guess we
-- shipped with.
INSERT INTO public.security_risk_weights (signal, weight, description) VALUES
  ('new_device',
   30,
   'First sign-in from this device on this account.'),
  ('new_country',
   35,
   'Country has never appeared in this account''s session history.'),
  ('recent_failed_attempts',
   20,
   'Three or more failed sign-ins against this identifier in the last hour.'),
  ('dormant_account',
   15,
   'No successful sign-in for 30 days before this one.'),
  ('threshold_alert',
   40,
   'At or above this score: record suspicious_login, notify in-app, send mail.'),
  ('threshold_challenge',
   70,
   'At or above this score: also demand an explicit "was this you?" answer.')
ON CONFLICT (signal) DO NOTHING;

-- No client ever reads the policy. Knowing the exact weights tells an attacker
-- precisely how to stay under the threshold.
ALTER TABLE public.security_risk_weights ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.security_risk_weights FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.security_risk_weights TO service_role;

CREATE OR REPLACE FUNCTION private.risk_weight(p_signal TEXT)
RETURNS INT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  -- A missing row scores zero rather than raising: deleting a weight should
  -- disable that signal, not break every sign-in on the platform.
  SELECT COALESCE(
    (SELECT w.weight FROM public.security_risk_weights w WHERE w.signal = p_signal),
    0
  );
$$;

REVOKE ALL ON FUNCTION private.risk_weight(TEXT)
  FROM PUBLIC, anon, authenticated;

-- ============================================================
-- 2. Notification kinds
-- ============================================================
-- Rewritten in full rather than appended to, because the constraint is a
-- single expression and a partial list would silently drop kinds that already
-- ship. Mirrors 20260716175655 plus the three security rows.
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;
ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind::TEXT IN (
    'comment_reply', 'post_like', 'comment_like', 'mention',
    'new_follower', 'friend_request', 'friend_accepted',
    'message_request', 'message_accepted',
    'tribe_prompt', 'tribe_invite', 'tribe_ownership_transfer',
    'whisper_reply', 'whisper_reaction',
    'moderation_action', 'admin_broadcast', 'system',
    -- Security kinds. Split three ways because each one wants a different
    -- response from the reader: nothing, a glance, or a decision.
    'security_alert',
    'security_new_device',
    'security_suspicious_login'
  ));

-- ============================================================
-- 3. The producer
-- ============================================================
-- public._notify() cannot be used here: it returns early when the actor is the
-- recipient, and every security alert is by definition about you. It also
-- groups, and collapsing two intrusion warnings into "and 1 other" would be a
-- bug with consequences. So this writes the row itself.
--
-- Mail goes straight into email_outbox rather than through queue_email(),
-- which derives its recipient from auth.uid(). That is right for a user
-- pressing a button and wrong for a trigger: an admin-initiated password reset
-- would address the mail to the admin, and a background job with no JWT at all
-- would raise 'not signed in' and abort the transaction that was trying to
-- warn someone their account had been taken.
CREATE OR REPLACE FUNCTION private.raise_security_alert(
  p_user_id     UUID,
  p_kind        TEXT,
  p_title       TEXT,
  p_body        TEXT,
  p_payload     JSONB DEFAULT '{}'::JSONB,
  p_email       BOOLEAN DEFAULT FALSE,
  p_template    TEXT DEFAULT 'security_alert',
  p_email_vars  JSONB DEFAULT '{}'::JSONB
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_recent_mail BOOLEAN;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO notifications (user_id, kind, actor_id, subject_type, payload)
  VALUES (
    p_user_id,
    p_kind,
    -- No actor. The system is speaking, and attributing this to a pseudonym
    -- would make a security warning look like social activity.
    NULL,
    'security',
    COALESCE(p_payload, '{}'::JSONB) || jsonb_build_object(
      'title', p_title,
      'body',  p_body
    )
  );

  IF NOT p_email THEN
    RETURN;
  END IF;

  -- A handset stuck in a registration loop, or a user rotating credentials
  -- while cleaning house, must not turn into a mailbox full of alarms. The
  -- in-app history above is already complete and unthrottled; this only
  -- rations the interrupt.
  SELECT EXISTS (
    SELECT 1 FROM email_outbox o
     WHERE o.user_id = p_user_id
       AND o.template IN ('security_alert', 'security_account_change')
       AND o.created_at > now() - INTERVAL '10 minutes'
  ) INTO v_recent_mail;

  IF v_recent_mail THEN
    RETURN;
  END IF;

  -- The dispatcher skips synthetic @id.venttly.app addresses on its own, so
  -- anonymous accounts cost one outbox row marked 'skipped' and no send.
  INSERT INTO email_outbox (user_id, template, variables)
  VALUES (p_user_id, p_template, COALESCE(p_email_vars, '{}'::JSONB));
END;
$$;

REVOKE ALL ON FUNCTION private.raise_security_alert(
  UUID, TEXT, TEXT, TEXT, JSONB, BOOLEAN, TEXT, JSONB
) FROM PUBLIC, anon, authenticated;

-- ============================================================
-- 4. Scoring a sign-in
-- ============================================================
-- Four signals, each cheap enough to run inline on the login path. Returns the
-- signals alongside the score so the security history can say *why* something
-- was flagged — an alert the user cannot interpret is an alert they cannot act
-- on.
--
-- Must be called before the 'success' login_attempts row is written and before
-- the new device_sessions row exists, or the sign-in being scored shows up in
-- its own history and every login looks familiar.
CREATE OR REPLACE FUNCTION private.evaluate_login_risk(
  p_user_id       UUID,
  p_device_row_id UUID,
  p_is_new_device BOOLEAN,
  p_country       TEXT
) RETURNS TABLE (
  score   INT,
  signals JSONB
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_score        INT := 0;
  v_signals      JSONB := '{}'::JSONB;
  v_trusted      BOOLEAN := FALSE;
  v_has_history  BOOLEAN := FALSE;
  v_new_country  BOOLEAN := FALSE;
  v_email        TEXT;
  v_hash         TEXT;
  v_failures     BIGINT := 0;
  v_last_success TIMESTAMPTZ;
BEGIN
  SELECT d.trusted_at IS NOT NULL INTO v_trusted
    FROM public.user_devices d
   WHERE d.device_row_id = p_device_row_id;

  IF p_is_new_device THEN
    v_score := v_score + private.risk_weight('new_device');
    v_signals := v_signals || jsonb_build_object('new_device', TRUE);
  END IF;

  -- New country only counts once the account HAS a country history. The first
  -- session an account ever opens is not suspicious for happening somewhere.
  IF p_country IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.device_sessions s
       WHERE s.user_id = p_user_id AND s.country IS NOT NULL
    ) INTO v_has_history;

    IF v_has_history THEN
      SELECT NOT EXISTS (
        SELECT 1 FROM public.device_sessions s
         WHERE s.user_id = p_user_id AND s.country = p_country
      ) INTO v_new_country;
    END IF;

    IF v_new_country THEN
      v_score := v_score + private.risk_weight('new_country');
      v_signals := v_signals || jsonb_build_object('new_country', p_country);
    END IF;
  END IF;

  -- record_failed_login() is reachable before authentication, so it stores a
  -- hashed identifier and no user id. Re-deriving the hash from the account's
  -- own address is the only way to connect a burst of guesses to the sign-in
  -- that followed it.
  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = p_user_id;
  IF v_email IS NOT NULL AND btrim(v_email) <> '' THEN
    v_hash := encode(digest(lower(btrim(v_email)), 'sha256'::text), 'hex');
    SELECT count(*) INTO v_failures
      FROM public.login_attempts a
     WHERE a.identifier_hash = v_hash
       AND a.outcome = 'failed'
       AND a.created_at > now() - INTERVAL '1 hour';

    IF v_failures >= 3 THEN
      v_score := v_score + private.risk_weight('recent_failed_attempts');
      v_signals := v_signals || jsonb_build_object('recent_failures', v_failures);
    END IF;
  END IF;

  -- A long-quiet account that suddenly wakes up is the classic credential-stuffing
  -- shape: the password leaked months ago and is only now being tried.
  SELECT max(a.created_at) INTO v_last_success
    FROM public.login_attempts a
   WHERE a.user_id = p_user_id AND a.outcome = 'success';

  IF v_last_success IS NOT NULL
     AND v_last_success < now() - INTERVAL '30 days' THEN
    v_score := v_score + private.risk_weight('dormant_account');
    v_signals := v_signals || jsonb_build_object('dormant_since', v_last_success);
  END IF;

  -- A device the user has explicitly vouched for keeps its score for the
  -- record but stops triggering. Trust is the whole point of asking.
  IF v_trusted THEN
    v_signals := v_signals || jsonb_build_object('trusted_device', TRUE);
  END IF;

  RETURN QUERY SELECT LEAST(v_score, 200), v_signals;
END;
$$;

REVOKE ALL ON FUNCTION private.evaluate_login_risk(UUID, UUID, BOOLEAN, TEXT)
  FROM PUBLIC, anon, authenticated;

-- ============================================================
-- 5. register_device_session, now with an opinion
-- ============================================================
-- The return type gains needs_confirmation, so the server owns the policy
-- decision instead of shipping a raw score and hoping every client applies the
-- same threshold. Changing a RETURNS TABLE shape requires a drop.
DROP FUNCTION IF EXISTS public.register_device_session(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
);

CREATE FUNCTION public.register_device_session(
  p_device_id   TEXT,
  p_device_name TEXT DEFAULT NULL,
  p_device_type TEXT DEFAULT 'unknown',
  p_os_name     TEXT DEFAULT NULL,
  p_os_version  TEXT DEFAULT NULL,
  p_app_version TEXT DEFAULT NULL
) RETURNS TABLE (
  device_row_id      UUID,
  device_session_id  UUID,
  is_new_device      BOOLEAN,
  is_blocked         BOOLEAN,
  risk_score         INT,
  needs_confirmation BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid       UUID := auth.uid();
  v_session   UUID := private.current_auth_session_id();
  v_device    public.user_devices%ROWTYPE;
  v_new       BOOLEAN := FALSE;
  v_country   TEXT;
  v_type      TEXT;
  v_ds_id     UUID;
  v_fresh     BOOLEAN := FALSE;
  v_score     INT := 0;
  v_signals   JSONB := '{}'::JSONB;
  v_alert_at  INT;
  v_chall_at  INT;
  v_challenge BOOLEAN := FALSE;
  v_label     TEXT;
  v_when      TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF p_device_id IS NULL OR length(p_device_id) < 8 OR length(p_device_id) > 128 THEN
    RAISE EXCEPTION 'invalid_device_id';
  END IF;

  -- A handset that re-registers in a tight loop is either broken or hostile.
  IF NOT public.claim_rate_limit('register_device_session', 60, 20) THEN
    RAISE EXCEPTION 'rate_limited' USING ERRCODE = 'P0001';
  END IF;

  v_type := COALESCE(NULLIF(p_device_type, ''), 'unknown');
  IF v_type NOT IN ('phone', 'tablet', 'desktop', 'web', 'unknown') THEN
    v_type := 'unknown';
  END IF;

  SELECT u.last_country INTO v_country FROM public.users u WHERE u.user_id = v_uid;

  SELECT * INTO v_device
    FROM public.user_devices d
   WHERE d.user_id = v_uid AND d.device_id = p_device_id
   FOR UPDATE;

  IF NOT FOUND THEN
    v_new := TRUE;
    INSERT INTO public.user_devices (
      user_id, device_id, device_name, device_type,
      os_name, os_version, app_version, last_country
    ) VALUES (
      v_uid, p_device_id, left(p_device_name, 80), v_type,
      left(p_os_name, 40), left(p_os_version, 40), left(p_app_version, 40), v_country
    )
    RETURNING * INTO v_device;
  ELSE
    UPDATE public.user_devices d
       SET device_name  = COALESCE(left(p_device_name, 80), d.device_name),
           device_type  = CASE WHEN v_type = 'unknown' THEN d.device_type ELSE v_type END,
           os_name      = COALESCE(left(p_os_name, 40), d.os_name),
           os_version   = COALESCE(left(p_os_version, 40), d.os_version),
           app_version  = COALESCE(left(p_app_version, 40), d.app_version),
           last_country = COALESCE(v_country, d.last_country),
           last_seen_at = now()
     WHERE d.device_row_id = v_device.device_row_id
     RETURNING * INTO v_device;
  END IF;

  v_label := COALESCE(v_device.device_name, initcap(v_device.device_type) || ' device');

  -- A device the user previously rejected does not get a session back.
  IF v_device.blocked_at IS NOT NULL THEN
    INSERT INTO public.login_attempts (user_id, device_id, outcome, country)
    VALUES (v_uid, p_device_id, 'blocked', v_country);

    PERFORM private.record_security_event(
      v_uid, 'login_blocked_device', 'critical', v_device.device_row_id, NULL,
      jsonb_build_object('device_name', v_device.device_name, 'country', v_country)
    );

    -- Worth an interrupt: somebody is still holding a device this account
    -- already disowned.
    PERFORM private.raise_security_alert(
      v_uid,
      'security_alert',
      'Blocked device tried to sign in',
      'A device you blocked tried to reach your account and was refused.',
      jsonb_build_object('device_row_id', v_device.device_row_id),
      TRUE,
      'security_account_change',
      jsonb_build_object(
        'headline', 'A blocked device tried to sign in',
        'detail', 'We refused a sign-in from ' || v_label ||
                  ', which you previously blocked. No action is needed unless ' ||
                  'you no longer recognise your account activity.',
        'when', to_char(now() AT TIME ZONE 'UTC', 'DD Mon YYYY HH24:MI') || ' UTC'
      )
    );

    RETURN QUERY SELECT v_device.device_row_id, NULL::UUID, FALSE, TRUE, 100, FALSE;
    RETURN;
  END IF;

  -- Reattach when the same GoTrue session calls again; otherwise open a row.
  IF v_session IS NOT NULL THEN
    SELECT s.device_session_id INTO v_ds_id
      FROM public.device_sessions s
     WHERE s.auth_session_id = v_session AND s.revoked_at IS NULL;
  END IF;

  IF v_ds_id IS NULL THEN
    v_fresh := TRUE;

    -- Strictly before the session row and the success attempt are written, or
    -- this sign-in becomes part of the history it is being compared against.
    SELECT r.score, r.signals INTO v_score, v_signals
      FROM private.evaluate_login_risk(
        v_uid, v_device.device_row_id, v_new, v_country
      ) r;

    INSERT INTO public.device_sessions (
      user_id, device_row_id, auth_session_id, country, app_version,
      risk_score, risk_signals
    ) VALUES (
      v_uid, v_device.device_row_id, v_session, v_country, left(p_app_version, 40),
      v_score, v_signals
    )
    RETURNING device_sessions.device_session_id INTO v_ds_id;
  ELSE
    UPDATE public.device_sessions s
       SET last_seen_at = now(),
           country      = COALESCE(v_country, s.country),
           app_version  = COALESCE(left(p_app_version, 40), s.app_version)
     WHERE s.device_session_id = v_ds_id
     RETURNING s.risk_score INTO v_score;
  END IF;

  INSERT INTO public.login_attempts (user_id, device_id, outcome, country)
  VALUES (v_uid, p_device_id, 'success', v_country);

  -- Everything below fires once per session, never on a cold-start reattach.
  -- Re-warning someone about a sign-in they already acknowledged is how a
  -- security surface becomes background noise.
  IF NOT v_fresh THEN
    RETURN QUERY SELECT v_device.device_row_id, v_ds_id, v_new, FALSE, v_score, FALSE;
    RETURN;
  END IF;

  v_alert_at := private.risk_weight('threshold_alert');
  v_chall_at := private.risk_weight('threshold_challenge');
  v_when     := to_char(now() AT TIME ZONE 'UTC', 'DD Mon YYYY HH24:MI') || ' UTC';

  -- A vouched-for device is exempt from both thresholds. That is what the user
  -- was promising when they trusted it.
  v_challenge := (v_device.trusted_at IS NULL)
                 AND v_alert_at > 0
                 AND v_score >= v_alert_at;

  IF v_challenge THEN
    PERFORM private.record_security_event(
      v_uid,
      'suspicious_login',
      CASE WHEN v_score >= v_chall_at THEN 'critical' ELSE 'warning' END,
      v_device.device_row_id,
      v_ds_id,
      jsonb_build_object(
        'device_name', v_device.device_name,
        'country', v_country,
        'risk_score', v_score,
        'signals', v_signals
      )
    );

    PERFORM private.raise_security_alert(
      v_uid,
      'security_suspicious_login',
      'Unusual sign-in',
      'We noticed a sign-in on ' || v_label || ' that looks unlike your usual '
        || 'activity. Tap to confirm it was you.',
      jsonb_build_object(
        'device_session_id', v_ds_id,
        'device_row_id', v_device.device_row_id,
        'risk_score', v_score
      ),
      TRUE,
      'security_alert',
      jsonb_build_object(
        'device', v_label,
        'when', v_when,
        'location', COALESCE(v_country, 'unknown')
      )
    );
  ELSE
    PERFORM private.record_security_event(
      v_uid,
      CASE WHEN v_new THEN 'login_new_device' ELSE 'login' END,
      CASE WHEN v_new THEN 'warning' ELSE 'info' END,
      v_device.device_row_id,
      v_ds_id,
      jsonb_build_object(
        'device_name', v_device.device_name,
        'device_type', v_device.device_type,
        'country', v_country,
        'risk_score', v_score,
        'signals', v_signals
      )
    );

    -- A new device below the alert threshold still deserves a line in the
    -- inbox. It just does not deserve an email or a decision.
    IF v_new AND v_device.trusted_at IS NULL THEN
      PERFORM private.raise_security_alert(
        v_uid,
        'security_new_device',
        'New device signed in',
        v_label || ' signed in to your account.',
        jsonb_build_object(
          'device_session_id', v_ds_id,
          'device_row_id', v_device.device_row_id
        ),
        FALSE
      );
    END IF;
  END IF;

  RETURN QUERY
    SELECT v_device.device_row_id,
           v_ds_id,
           v_new,
           FALSE,
           v_score,
           (v_challenge AND v_chall_at > 0 AND v_score >= v_chall_at);
END;
$$;

REVOKE ALL ON FUNCTION public.register_device_session(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_device_session(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  TO authenticated;

-- ============================================================
-- 6. What still needs an answer
-- ============================================================
-- Sessions the account was warned about and never adjudicated. The app polls
-- this on resume: a flagged sign-in that the user never saw because they were
-- not holding their phone at the time is exactly the case that matters.
CREATE OR REPLACE FUNCTION public.my_unresolved_security_alerts()
RETURNS TABLE (
  device_session_id UUID,
  device_row_id     UUID,
  device_name       TEXT,
  device_type       TEXT,
  os_name           TEXT,
  country           TEXT,
  risk_score        INT,
  risk_signals      JSONB,
  is_current        BOOLEAN,
  started_at        TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_session UUID := private.current_auth_session_id();
  v_alert   INT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  v_alert := private.risk_weight('threshold_alert');
  IF v_alert <= 0 THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT s.device_session_id,
           d.device_row_id,
           d.device_name,
           d.device_type,
           d.os_name,
           COALESCE(s.country, d.last_country),
           s.risk_score,
           s.risk_signals,
           (v_session IS NOT NULL AND s.auth_session_id = v_session),
           s.started_at
      FROM public.device_sessions s
      JOIN public.user_devices d ON d.device_row_id = s.device_row_id
     WHERE s.user_id = v_uid
       AND s.revoked_at IS NULL
       AND s.confirmed_at IS NULL
       AND s.risk_score >= v_alert
       AND d.trusted_at IS NULL
       AND d.blocked_at IS NULL
       -- A week is long enough to catch someone who was away and short enough
       -- that the prompt still refers to something they might remember.
       AND s.started_at > now() - INTERVAL '7 days'
     ORDER BY s.risk_score DESC, s.started_at DESC
     LIMIT 5;
END;
$$;

REVOKE ALL ON FUNCTION public.my_unresolved_security_alerts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_unresolved_security_alerts() TO authenticated;

-- ============================================================
-- 7. Answering it
-- ============================================================
-- One RPC for both answers, because they are one decision and splitting them
-- invites a client that implements the reassuring half and forgets the other.
--
-- "That was me" trusts the device outright. Slightly generous — but a prompt
-- the user has to re-answer every morning is a prompt they will answer without
-- reading, and an unread prompt protects nobody.
CREATE OR REPLACE FUNCTION public.resolve_suspicious_login(
  p_device_session_id UUID,
  p_was_me            BOOLEAN
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_session UUID := private.current_auth_session_id();
  v_device  UUID;
  v_label   TEXT;
  v_score   INT;
  v_ended   INT := 0;
  v_row     RECORD;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF p_was_me IS NULL THEN
    RAISE EXCEPTION 'answer_required';
  END IF;

  IF NOT public.claim_rate_limit('resolve_suspicious_login', 3600, 60) THEN
    RAISE EXCEPTION 'rate_limited' USING ERRCODE = 'P0001';
  END IF;

  SELECT s.device_row_id, d.device_name, s.risk_score
    INTO v_device, v_label, v_score
    FROM public.device_sessions s
    JOIN public.user_devices d ON d.device_row_id = s.device_row_id
   WHERE s.device_session_id = p_device_session_id
     AND s.user_id = v_uid;

  IF v_device IS NULL THEN
    RETURN FALSE;
  END IF;

  IF p_was_me THEN
    UPDATE public.user_devices d
       SET trusted_at = now(),
           blocked_at = NULL
     WHERE d.device_row_id = v_device
       AND d.user_id = v_uid;

    -- Every live session on the device, not just the flagged one: the user
    -- just told us the hardware is theirs.
    UPDATE public.device_sessions s
       SET confirmed_at = now()
     WHERE s.device_row_id = v_device
       AND s.user_id = v_uid
       AND s.revoked_at IS NULL;

    PERFORM private.record_security_event(
      v_uid, 'suspicious_login_confirmed', 'info', v_device, p_device_session_id,
      jsonb_build_object('device_name', v_label, 'risk_score', v_score)
    );

    RETURN TRUE;
  END IF;

  -- "That wasn't me." Block the hardware, then end every session on it except
  -- the one the user is holding — being signed out mid-recovery is how people
  -- abandon recovery.
  UPDATE public.user_devices d
     SET blocked_at = now(),
         trusted_at = NULL
   WHERE d.device_row_id = v_device
     AND d.user_id = v_uid;

  FOR v_row IN
    SELECT s.device_session_id
      FROM public.device_sessions s
     WHERE s.device_row_id = v_device
       AND s.user_id = v_uid
       AND s.revoked_at IS NULL
       AND (v_session IS NULL OR s.auth_session_id IS DISTINCT FROM v_session)
  LOOP
    IF private.end_device_session(
         v_row.device_session_id, v_uid, 'suspicious_rejected'
       ) THEN
      v_ended := v_ended + 1;
    END IF;
  END LOOP;

  PERFORM private.record_security_event(
    v_uid, 'suspicious_login_rejected', 'critical', v_device, p_device_session_id,
    jsonb_build_object(
      'device_name', v_label,
      'risk_score', v_score,
      'sessions_ended', v_ended
    )
  );

  -- Deliberately not throttled behind the 10-minute mail guard's intent: this
  -- is the one message that tells the user what to do next, and it is the
  -- direct result of them pressing a button.
  PERFORM private.raise_security_alert(
    v_uid,
    'security_alert',
    'Device blocked',
    'We blocked ' || COALESCE(v_label, 'that device') || ' and ended its sessions. '
      || 'Change your password to finish securing your account.',
    jsonb_build_object('device_row_id', v_device),
    TRUE,
    'security_account_change',
    jsonb_build_object(
      'headline', 'We blocked a device on your account',
      'detail', 'You reported a sign-in as not yours. That device is blocked and '
                || 'its sessions are closed. Change your password now — whoever '
                || 'signed in knew it.',
      'when', to_char(now() AT TIME ZONE 'UTC', 'DD Mon YYYY HH24:MI') || ' UTC'
    )
  );

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_suspicious_login(UUID, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_suspicious_login(UUID, BOOLEAN) TO authenticated;

-- ============================================================
-- 8. Account changes now reach the user
-- ============================================================
-- The password trigger from 20260828230000 recorded history and told nobody.
-- History is what you read after you already suspect something; a notification
-- is what makes you suspect it.
CREATE OR REPLACE FUNCTION private.on_auth_password_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.encrypted_password IS DISTINCT FROM OLD.encrypted_password THEN
    UPDATE public.users u
       SET password_changed_at = now()
     WHERE u.user_id = NEW.id;

    PERFORM private.record_security_event(
      NEW.id, 'password_changed', 'warning', NULL, NULL, '{}'::JSONB
    );

    -- Only a genuine rotation. GoTrue sets the first password by moving the
    -- column off NULL, and greeting a brand new account with "your password
    -- was changed" is both alarming and false.
    IF OLD.encrypted_password IS NOT NULL AND OLD.encrypted_password <> '' THEN
      PERFORM private.raise_security_alert(
        NEW.id,
        'security_alert',
        'Password changed',
        'Your Venttly password was changed. If this wasn''t you, secure your '
          || 'account now.',
        '{}'::JSONB,
        TRUE,
        'security_account_change',
        jsonb_build_object(
          'headline', 'Your password was changed',
          'detail', 'If you did not make this change, someone else has access to '
                    || 'your account. Reset your password and sign out every device.',
          'when', to_char(now() AT TIME ZONE 'UTC', 'DD Mon YYYY HH24:MI') || ' UTC'
        )
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.on_auth_password_changed()
  FROM PUBLIC, anon, authenticated;

-- Turning two-factor off is the single highest-signal account change there is:
-- it is step one of taking an account, and step zero of losing one.
CREATE OR REPLACE FUNCTION public.log_my_security_event(
  p_kind    TEXT,
  p_context JSONB DEFAULT '{}'::JSONB
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   UUID := auth.uid();
  v_event UUID;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF p_kind NOT IN (
    'two_factor_enabled',
    'two_factor_disabled',
    'recovery_email_changed',
    'recovery_phrase_rotated'
  ) THEN
    RAISE EXCEPTION 'unsupported_security_event_kind';
  END IF;

  IF NOT public.claim_rate_limit('log_security_event', 3600, 40) THEN
    RAISE EXCEPTION 'rate_limited' USING ERRCODE = 'P0001';
  END IF;

  v_event := private.record_security_event(
    v_uid,
    p_kind,
    CASE WHEN p_kind = 'two_factor_disabled' THEN 'warning' ELSE 'info' END,
    NULL,
    NULL,
    -- Only a fixed, non-sensitive subset is kept; arbitrary client JSON does
    -- not get to land in a security log.
    jsonb_strip_nulls(jsonb_build_object(
      'source', 'client',
      'masked_email', left(COALESCE(p_context ->> 'masked_email', ''), 64)
    ))
  );

  IF p_kind = 'two_factor_disabled' THEN
    PERFORM private.raise_security_alert(
      v_uid,
      'security_alert',
      'Two-factor authentication turned off',
      'Two-factor authentication is no longer protecting your account.',
      '{}'::JSONB,
      TRUE,
      'security_account_change',
      jsonb_build_object(
        'headline', 'Two-factor authentication was turned off',
        'detail', 'Your account is now protected by your password alone. If you '
                  || 'did not do this, turn two-factor back on and change your '
                  || 'password.',
        'when', to_char(now() AT TIME ZONE 'UTC', 'DD Mon YYYY HH24:MI') || ' UTC'
      )
    );
  END IF;

  RETURN v_event;
END;
$$;

REVOKE ALL ON FUNCTION public.log_my_security_event(TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.log_my_security_event(TEXT, JSONB) TO authenticated;

SELECT public.record_migration(
  '20260829180000',
  'login_risk_scoring_and_security_alerts'
);

NOTIFY pgrst, 'reload schema';
