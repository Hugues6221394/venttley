-- Device identity, session visibility, and a user-owned security ledger.
--
-- Until now Venttly had no concept of a device. That single absence is why a
-- user could not see where they were signed in, could not evict an intruder
-- without signing themselves out too, and never learned that either had
-- happened. Four separate gaps, one missing noun.
--
-- What lands here:
--
--   user_devices      one row per (account, physical device). Carries the
--                     trusted and blocked flags directly rather than in two
--                     satellite tables — a device has one lifecycle, and
--                     splitting it across three tables buys nothing but joins.
--   device_sessions   one row per sign-in on a device, bound to GoTrue's own
--                     session id so revocation is real and not cosmetic.
--   security_events   append-only, user-readable history. Enforced immutable
--                     by trigger, not by convention.
--   login_attempts    outcome ledger feeding the risk signals that arrive in
--                     the next migration.
--
-- Revocation semantics, stated plainly: deleting the auth.sessions row stops
-- the refresh token immediately, but an already-issued access token stays
-- valid until it expires (jwt_expiry = 3600). touch_device_session() closes
-- that window — the client heartbeat already runs every 60s, so a revoked
-- device discovers it within a minute instead of an hour.
--
-- Precedents followed: auth.sessions is read the way 0106 reads it, the
-- private schema is used the way 20260714182652 uses it, and the auth.users
-- trigger mirrors on_auth_user_created from 0002.

-- ============================================================
-- 1. When the password last changed
-- ============================================================
-- The security checkup claimed "password protects your account" as a static
-- truth. A date makes it a fact the user can act on.
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS password_changed_at TIMESTAMPTZ;

COMMENT ON COLUMN public.users.password_changed_at IS
  'Set by the auth.users password trigger. NULL means never rotated since the column landed.';

-- ============================================================
-- 2. Which GoTrue session is making this request
-- ============================================================
-- GoTrue puts session_id in the access-token claims. Read defensively: a
-- deployment that ever stops emitting it must degrade to "unknown session",
-- not break every sign-in.
CREATE OR REPLACE FUNCTION private.current_auth_session_id()
RETURNS UUID
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_claims TEXT;
BEGIN
  v_claims := NULLIF(current_setting('request.jwt.claims', TRUE), '');
  IF v_claims IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN NULLIF(v_claims::JSONB ->> 'session_id', '')::UUID;
EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION private.current_auth_session_id()
  FROM PUBLIC, anon, authenticated;

-- ============================================================
-- 3. user_devices
-- ============================================================
CREATE TABLE IF NOT EXISTS public.user_devices (
  device_row_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,

  -- Client-generated, stored in the platform keystore. Opaque to the server;
  -- bounded so it cannot become a smuggling channel for arbitrary payloads.
  device_id     TEXT NOT NULL CHECK (length(device_id) BETWEEN 8 AND 128),

  device_name   TEXT CHECK (device_name IS NULL OR length(device_name) <= 80),
  device_type   TEXT NOT NULL DEFAULT 'unknown'
                  CHECK (device_type IN ('phone', 'tablet', 'desktop', 'web', 'unknown')),
  os_name       TEXT CHECK (os_name IS NULL OR length(os_name) <= 40),
  os_version    TEXT CHECK (os_version IS NULL OR length(os_version) <= 40),
  app_version   TEXT CHECK (app_version IS NULL OR length(app_version) <= 40),

  -- ISO-3166 alpha-2 only. Approximate by construction — it comes from the CDN
  -- edge header via geo-capture, never from GPS, and the UI must not imply
  -- otherwise.
  last_country  TEXT CHECK (last_country IS NULL OR last_country ~ '^[A-Z]{2}$'),

  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- A device the user has vouched for. Suppresses repeat "was this you?"
  -- prompts once the risk engine lands.
  trusted_at    TIMESTAMPTZ,

  -- A device the user rejected. Blocked devices are refused at registration,
  -- so a stolen credential cannot re-establish a session from the same handset.
  blocked_at    TIMESTAMPTZ,

  UNIQUE (user_id, device_id)
);

COMMENT ON TABLE public.user_devices IS
  'One row per account/device pair. trusted_at and blocked_at carry the device lifecycle inline.';

CREATE INDEX IF NOT EXISTS idx_user_devices_user_seen
  ON public.user_devices (user_id, last_seen_at DESC);

-- ============================================================
-- 4. device_sessions
-- ============================================================
CREATE TABLE IF NOT EXISTS public.device_sessions (
  device_session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  device_row_id     UUID NOT NULL REFERENCES public.user_devices(device_row_id) ON DELETE CASCADE,

  -- The GoTrue session this row shadows. Nullable because a token without the
  -- claim still deserves a visible row; such a row simply cannot be revoked at
  -- the auth layer and is revoked by flag alone.
  auth_session_id   UUID,

  country           TEXT CHECK (country IS NULL OR country ~ '^[A-Z]{2}$'),
  app_version       TEXT CHECK (app_version IS NULL OR length(app_version) <= 40),

  -- Populated by the risk engine in the next migration. Present now so the
  -- shape does not churn once scoring arrives.
  risk_score        INT NOT NULL DEFAULT 0 CHECK (risk_score BETWEEN 0 AND 200),
  risk_signals      JSONB NOT NULL DEFAULT '{}'::JSONB,
  confirmed_at      TIMESTAMPTZ,

  started_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at        TIMESTAMPTZ,
  revoked_reason    TEXT CHECK (
                      revoked_reason IS NULL OR revoked_reason IN (
                        'user_revoked',
                        'user_revoked_all',
                        'password_changed',
                        'suspicious_rejected',
                        'device_blocked'
                      )
                    )
);

COMMENT ON TABLE public.device_sessions IS
  'One row per sign-in, shadowing a GoTrue session so the user can see and end it.';

-- At most one *live* shadow row per GoTrue session. Scoped to revoked_at IS
-- NULL rather than the whole table: revoked rows are history and must not stop
-- the same session id from being registered again.
DROP INDEX IF EXISTS public.idx_device_sessions_auth_session;
CREATE UNIQUE INDEX idx_device_sessions_auth_session
  ON public.device_sessions (auth_session_id)
  WHERE auth_session_id IS NOT NULL AND revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_device_sessions_user_active
  ON public.device_sessions (user_id, last_seen_at DESC)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_device_sessions_device
  ON public.device_sessions (device_row_id, started_at DESC);

-- ============================================================
-- 5. security_events — append only
-- ============================================================
CREATE TABLE IF NOT EXISTS public.security_events (
  event_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,

  kind              TEXT NOT NULL CHECK (kind IN (
                      'login',
                      'login_new_device',
                      'login_blocked_device',
                      'suspicious_login',
                      'suspicious_login_confirmed',
                      'suspicious_login_rejected',
                      'password_changed',
                      'two_factor_enabled',
                      'two_factor_disabled',
                      'recovery_email_changed',
                      'recovery_phrase_rotated',
                      'device_trusted',
                      'device_revoked',
                      'device_blocked',
                      'sessions_revoked_all'
                    )),

  severity          TEXT NOT NULL DEFAULT 'info'
                      CHECK (severity IN ('info', 'warning', 'critical')),

  device_row_id     UUID REFERENCES public.user_devices(device_row_id) ON DELETE SET NULL,
  device_session_id UUID REFERENCES public.device_sessions(device_session_id) ON DELETE SET NULL,

  -- Display context only: device label, country, app version. Never tokens,
  -- never password material, never an IP address.
  context           JSONB NOT NULL DEFAULT '{}'::JSONB,

  -- clock_timestamp(), not now(): now() is the transaction timestamp, so two
  -- events written by the same RPC would tie and the history would have no
  -- stable order. This is a log, and a log has to know what came first.
  created_at        TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE public.security_events IS
  'User-visible security history. Append-only: the immutability trigger rejects UPDATE and DELETE from every role.';

-- Stated separately so re-applying this file over an existing table still
-- corrects the default; CREATE TABLE IF NOT EXISTS would silently skip it.
ALTER TABLE public.security_events
  ALTER COLUMN created_at SET DEFAULT clock_timestamp();

CREATE INDEX IF NOT EXISTS idx_security_events_user_time
  ON public.security_events (user_id, created_at DESC);

-- Immutability is enforced here rather than by grants alone, so a future
-- migration that hands out UPDATE by accident still cannot rewrite history.
CREATE OR REPLACE FUNCTION private.guard_security_events_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'security_events is append-only'
    USING ERRCODE = 'P0001';
END;
$$;

REVOKE ALL ON FUNCTION private.guard_security_events_append_only()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS security_events_append_only ON public.security_events;
CREATE TRIGGER security_events_append_only
  BEFORE UPDATE OR DELETE ON public.security_events
  FOR EACH ROW EXECUTE FUNCTION private.guard_security_events_append_only();

-- ============================================================
-- 6. login_attempts
-- ============================================================
CREATE TABLE IF NOT EXISTS public.login_attempts (
  attempt_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- NULL for a failure against an identifier that resolved to nobody.
  user_id         UUID REFERENCES public.users(user_id) ON DELETE CASCADE,

  -- Hashed, never raw. Lets the risk engine count attempts against one
  -- identifier without the table becoming a username directory.
  identifier_hash TEXT CHECK (identifier_hash IS NULL OR length(identifier_hash) = 64),

  device_id       TEXT CHECK (device_id IS NULL OR length(device_id) BETWEEN 8 AND 128),
  outcome         TEXT NOT NULL
                    CHECK (outcome IN ('success', 'failed', 'blocked', 'mfa_required')),
  country         TEXT CHECK (country IS NULL OR country ~ '^[A-Z]{2}$'),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.login_attempts IS
  'Sign-in outcome ledger. No IP addresses, no raw identifiers. Service-role and definer access only.';

CREATE INDEX IF NOT EXISTS idx_login_attempts_user_time
  ON public.login_attempts (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_login_attempts_identifier_time
  ON public.login_attempts (identifier_hash, created_at DESC)
  WHERE identifier_hash IS NOT NULL;

-- ============================================================
-- 7. Row Level Security
-- ============================================================
-- Reads are owner-scoped. Every write goes through a SECURITY DEFINER RPC, so
-- no table below has an INSERT, UPDATE, or DELETE policy at all.

ALTER TABLE public.user_devices    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.security_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.login_attempts  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_devices_owner_read ON public.user_devices;
CREATE POLICY user_devices_owner_read
  ON public.user_devices FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS device_sessions_owner_read ON public.device_sessions;
CREATE POLICY device_sessions_owner_read
  ON public.device_sessions FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS security_events_owner_read ON public.security_events;
CREATE POLICY security_events_owner_read
  ON public.security_events FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- login_attempts deliberately has no policy. Even the owner reads it only
-- through an RPC that returns counts, never rows.

REVOKE ALL ON TABLE public.user_devices    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.device_sessions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.security_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.login_attempts  FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.user_devices    TO authenticated;
GRANT SELECT ON public.device_sessions TO authenticated;
GRANT SELECT ON public.security_events TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_devices    TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.device_sessions TO service_role;
GRANT SELECT, INSERT                 ON public.security_events TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.login_attempts  TO service_role;

-- ============================================================
-- 8. Writing a security event
-- ============================================================
CREATE OR REPLACE FUNCTION private.record_security_event(
  p_user_id           UUID,
  p_kind              TEXT,
  p_severity          TEXT DEFAULT 'info',
  p_device_row_id     UUID DEFAULT NULL,
  p_device_session_id UUID DEFAULT NULL,
  p_context           JSONB DEFAULT '{}'::JSONB
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_id UUID;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO security_events (
    user_id, kind, severity, device_row_id, device_session_id, context
  ) VALUES (
    p_user_id,
    p_kind,
    COALESCE(p_severity, 'info'),
    p_device_row_id,
    p_device_session_id,
    COALESCE(p_context, '{}'::JSONB)
  )
  RETURNING event_id INTO v_event_id;

  RETURN v_event_id;
END;
$$;

REVOKE ALL ON FUNCTION private.record_security_event(UUID, TEXT, TEXT, UUID, UUID, JSONB)
  FROM PUBLIC, anon, authenticated;

-- ============================================================
-- 9. register_device_session
-- ============================================================
-- Called once per sign-in, and again on cold start so a session that outlived
-- the app process reattaches to its row instead of orphaning it.
--
-- Returns is_blocked rather than raising, because the caller needs to sign
-- itself out cleanly; an exception here would surface as an opaque failure on
-- the login screen.
CREATE OR REPLACE FUNCTION public.register_device_session(
  p_device_id   TEXT,
  p_device_name TEXT DEFAULT NULL,
  p_device_type TEXT DEFAULT 'unknown',
  p_os_name     TEXT DEFAULT NULL,
  p_os_version  TEXT DEFAULT NULL,
  p_app_version TEXT DEFAULT NULL
) RETURNS TABLE (
  device_row_id     UUID,
  device_session_id UUID,
  is_new_device     BOOLEAN,
  is_blocked        BOOLEAN,
  risk_score        INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid        UUID := auth.uid();
  v_session    UUID := private.current_auth_session_id();
  v_device     public.user_devices%ROWTYPE;
  v_new        BOOLEAN := FALSE;
  v_country    TEXT;
  v_type       TEXT;
  v_ds_id      UUID;
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

  -- A device the user previously rejected does not get a session back.
  IF v_device.blocked_at IS NOT NULL THEN
    INSERT INTO public.login_attempts (user_id, device_id, outcome, country)
    VALUES (v_uid, p_device_id, 'blocked', v_country);

    PERFORM private.record_security_event(
      v_uid, 'login_blocked_device', 'critical', v_device.device_row_id, NULL,
      jsonb_build_object('device_name', v_device.device_name, 'country', v_country)
    );

    RETURN QUERY SELECT v_device.device_row_id, NULL::UUID, FALSE, TRUE, 100;
    RETURN;
  END IF;

  -- Reattach when the same GoTrue session calls again; otherwise open a row.
  IF v_session IS NOT NULL THEN
    SELECT s.device_session_id INTO v_ds_id
      FROM public.device_sessions s
     WHERE s.auth_session_id = v_session AND s.revoked_at IS NULL;
  END IF;

  IF v_ds_id IS NULL THEN
    INSERT INTO public.device_sessions (
      user_id, device_row_id, auth_session_id, country, app_version
    ) VALUES (
      v_uid, v_device.device_row_id, v_session, v_country, left(p_app_version, 40)
    )
    RETURNING device_sessions.device_session_id INTO v_ds_id;
  ELSE
    UPDATE public.device_sessions s
       SET last_seen_at = now(),
           country      = COALESCE(v_country, s.country),
           app_version  = COALESCE(left(p_app_version, 40), s.app_version)
     WHERE s.device_session_id = v_ds_id;
  END IF;

  INSERT INTO public.login_attempts (user_id, device_id, outcome, country)
  VALUES (v_uid, p_device_id, 'success', v_country);

  PERFORM private.record_security_event(
    v_uid,
    CASE WHEN v_new THEN 'login_new_device' ELSE 'login' END,
    CASE WHEN v_new THEN 'warning' ELSE 'info' END,
    v_device.device_row_id,
    v_ds_id,
    jsonb_build_object(
      'device_name', v_device.device_name,
      'device_type', v_device.device_type,
      'country', v_country
    )
  );

  RETURN QUERY SELECT v_device.device_row_id, v_ds_id, v_new, FALSE, 0;
END;
$$;

REVOKE ALL ON FUNCTION public.register_device_session(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_device_session(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  TO authenticated;

-- ============================================================
-- 10. my_device_sessions
-- ============================================================
CREATE OR REPLACE FUNCTION public.my_device_sessions()
RETURNS TABLE (
  device_session_id UUID,
  device_row_id     UUID,
  device_name       TEXT,
  device_type       TEXT,
  os_name           TEXT,
  os_version        TEXT,
  app_version       TEXT,
  country           TEXT,
  is_current        BOOLEAN,
  is_trusted        BOOLEAN,
  risk_score        INT,
  started_at        TIMESTAMPTZ,
  last_seen_at      TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_session UUID := private.current_auth_session_id();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  RETURN QUERY
    SELECT s.device_session_id,
           d.device_row_id,
           d.device_name,
           d.device_type,
           d.os_name,
           d.os_version,
           s.app_version,
           COALESCE(s.country, d.last_country),
           (v_session IS NOT NULL AND s.auth_session_id = v_session),
           (d.trusted_at IS NOT NULL),
           s.risk_score,
           s.started_at,
           s.last_seen_at
      FROM public.device_sessions s
      JOIN public.user_devices d ON d.device_row_id = s.device_row_id
     WHERE s.user_id = v_uid
       AND s.revoked_at IS NULL
     ORDER BY (v_session IS NOT NULL AND s.auth_session_id = v_session) DESC,
              s.last_seen_at DESC
     LIMIT 50;
END;
$$;

REVOKE ALL ON FUNCTION public.my_device_sessions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_device_sessions() TO authenticated;

-- ============================================================
-- 11. Ending sessions
-- ============================================================
-- Shared by every revoke path. Flags the shadow row and drops the GoTrue
-- session in one place so the two can never disagree.
CREATE OR REPLACE FUNCTION private.end_device_session(
  p_device_session_id UUID,
  p_user_id           UUID,
  p_reason            TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_auth_session UUID;
BEGIN
  UPDATE public.device_sessions s
     SET revoked_at     = now(),
         revoked_reason = p_reason
   WHERE s.device_session_id = p_device_session_id
     AND s.user_id = p_user_id
     AND s.revoked_at IS NULL
  RETURNING s.auth_session_id INTO v_auth_session;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  -- Kills the refresh token now. The outstanding access token still works
  -- until it expires; touch_device_session closes that gap.
  IF v_auth_session IS NOT NULL THEN
    DELETE FROM auth.sessions WHERE id = v_auth_session AND user_id = p_user_id;
  END IF;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION private.end_device_session(UUID, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.revoke_device_session(p_device_session_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid    UUID := auth.uid();
  v_device UUID;
  v_label  TEXT;
  v_ok     BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT s.device_row_id, d.device_name
    INTO v_device, v_label
    FROM public.device_sessions s
    JOIN public.user_devices d ON d.device_row_id = s.device_row_id
   WHERE s.device_session_id = p_device_session_id
     AND s.user_id = v_uid;

  IF v_device IS NULL THEN
    RETURN FALSE;
  END IF;

  v_ok := private.end_device_session(p_device_session_id, v_uid, 'user_revoked');
  IF NOT v_ok THEN
    RETURN FALSE;
  END IF;

  PERFORM private.record_security_event(
    v_uid, 'device_revoked', 'warning', v_device, p_device_session_id,
    jsonb_build_object('device_name', v_label)
  );

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_device_session(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_device_session(UUID) TO authenticated;

-- Everything except the caller's own session. Deliberately not "everywhere":
-- signing the user out of the device they are holding is a different, more
-- destructive action and keeps its existing global sign-out path.
CREATE OR REPLACE FUNCTION public.revoke_other_device_sessions()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_session UUID := private.current_auth_session_id();
  v_row     RECORD;
  v_count   INT := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  FOR v_row IN
    SELECT s.device_session_id
      FROM public.device_sessions s
     WHERE s.user_id = v_uid
       AND s.revoked_at IS NULL
       AND (v_session IS NULL OR s.auth_session_id IS DISTINCT FROM v_session)
  LOOP
    IF private.end_device_session(v_row.device_session_id, v_uid, 'user_revoked_all') THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  IF v_count > 0 THEN
    PERFORM private.record_security_event(
      v_uid, 'sessions_revoked_all', 'warning', NULL, NULL,
      jsonb_build_object('revoked_count', v_count)
    );
  END IF;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_other_device_sessions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_other_device_sessions() TO authenticated;

-- ============================================================
-- 12. touch_device_session — the heartbeat that makes revocation bite
-- ============================================================
-- Returns FALSE when this session has been revoked or its device blocked. The
-- client already pings every 60s for presence; piggybacking here turns an
-- hour-long access-token window into a minute.
CREATE OR REPLACE FUNCTION public.touch_device_session()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_session UUID := private.current_auth_session_id();
  v_row     RECORD;
BEGIN
  IF v_uid IS NULL THEN
    RETURN FALSE;
  END IF;

  -- No session claim means nothing to check against; do not lock the user out
  -- over a token shape we cannot read.
  IF v_session IS NULL THEN
    RETURN TRUE;
  END IF;

  SELECT s.device_session_id, s.revoked_at, d.blocked_at
    INTO v_row
    FROM public.device_sessions s
    JOIN public.user_devices d ON d.device_row_id = s.device_row_id
   WHERE s.auth_session_id = v_session
     AND s.user_id = v_uid;

  -- Unregistered session: the app registers on next cold start.
  IF NOT FOUND THEN
    RETURN TRUE;
  END IF;

  IF v_row.revoked_at IS NOT NULL OR v_row.blocked_at IS NOT NULL THEN
    RETURN FALSE;
  END IF;

  UPDATE public.device_sessions s
     SET last_seen_at = now()
   WHERE s.device_session_id = v_row.device_session_id;

  UPDATE public.user_devices d
     SET last_seen_at = now()
   WHERE d.device_row_id = (
     SELECT s.device_row_id FROM public.device_sessions s
      WHERE s.device_session_id = v_row.device_session_id
   );

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.touch_device_session() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.touch_device_session() TO authenticated;

-- ============================================================
-- 13. Trusting and blocking a device
-- ============================================================
CREATE OR REPLACE FUNCTION public.trust_device(p_device_row_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   UUID := auth.uid();
  v_label TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  UPDATE public.user_devices d
     SET trusted_at = now(),
         blocked_at = NULL
   WHERE d.device_row_id = p_device_row_id
     AND d.user_id = v_uid
  RETURNING d.device_name INTO v_label;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  UPDATE public.device_sessions s
     SET confirmed_at = now()
   WHERE s.device_row_id = p_device_row_id
     AND s.user_id = v_uid
     AND s.revoked_at IS NULL;

  PERFORM private.record_security_event(
    v_uid, 'device_trusted', 'info', p_device_row_id, NULL,
    jsonb_build_object('device_name', v_label)
  );

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.trust_device(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.trust_device(UUID) TO authenticated;

-- "No, secure my account": block the device and end every session on it. The
-- caller's own session survives — a user reporting an intruder must not be
-- signed out mid-recovery.
CREATE OR REPLACE FUNCTION public.block_device(p_device_row_id UUID)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_session UUID := private.current_auth_session_id();
  v_label   TEXT;
  v_row     RECORD;
  v_count   INT := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  UPDATE public.user_devices d
     SET blocked_at = now(),
         trusted_at = NULL
   WHERE d.device_row_id = p_device_row_id
     AND d.user_id = v_uid
  RETURNING d.device_name INTO v_label;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  FOR v_row IN
    SELECT s.device_session_id
      FROM public.device_sessions s
     WHERE s.device_row_id = p_device_row_id
       AND s.user_id = v_uid
       AND s.revoked_at IS NULL
       AND (v_session IS NULL OR s.auth_session_id IS DISTINCT FROM v_session)
  LOOP
    IF private.end_device_session(v_row.device_session_id, v_uid, 'device_blocked') THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  PERFORM private.record_security_event(
    v_uid, 'device_blocked', 'critical', p_device_row_id, NULL,
    jsonb_build_object('device_name', v_label, 'sessions_ended', v_count)
  );

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.block_device(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.block_device(UUID) TO authenticated;

-- ============================================================
-- 14. Reading the security history
-- ============================================================
-- Keyset pagination on created_at. The list is append-only and read newest
-- first, so an offset would drift as new events land.
CREATE OR REPLACE FUNCTION public.my_security_events(
  p_limit  INT DEFAULT 30,
  p_before TIMESTAMPTZ DEFAULT NULL
) RETURNS TABLE (
  event_id    UUID,
  kind        TEXT,
  severity    TEXT,
  device_name TEXT,
  context     JSONB,
  created_at  TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   UUID := auth.uid();
  v_limit INT  := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  RETURN QUERY
    SELECT e.event_id,
           e.kind,
           e.severity,
           d.device_name,
           e.context,
           e.created_at
      FROM public.security_events e
      LEFT JOIN public.user_devices d ON d.device_row_id = e.device_row_id
     WHERE e.user_id = v_uid
       AND (p_before IS NULL OR e.created_at < p_before)
     ORDER BY e.created_at DESC, e.event_id DESC
     LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.my_security_events(INT, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_security_events(INT, TIMESTAMPTZ) TO authenticated;

-- ============================================================
-- 15. Self-attested security events
-- ============================================================
-- 2FA and recovery-email changes happen inside GoTrue, where no trigger of
-- ours runs. The client reports them so the history is complete.
--
-- The allowlist matters: a user can only write low-stakes rows about their own
-- account, never a 'login_blocked_device' or anything the risk engine owns.
-- Worst case they add noise to their own log.
CREATE OR REPLACE FUNCTION public.log_my_security_event(
  p_kind    TEXT,
  p_context JSONB DEFAULT '{}'::JSONB
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
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

  RETURN private.record_security_event(
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
END;
$$;

REVOKE ALL ON FUNCTION public.log_my_security_event(TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.log_my_security_event(TEXT, JSONB) TO authenticated;

-- ============================================================
-- 16. Password changes, recorded where they actually happen
-- ============================================================
-- GoTrue owns the password. A trigger on auth.users is the only place that
-- sees every rotation — console resets included — and it cannot be spoofed by
-- a client the way a self-reported event could. Mirrors the existing
-- on_auth_user_created trigger from 0002.
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
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.on_auth_password_changed()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS on_auth_password_changed ON auth.users;
CREATE TRIGGER on_auth_password_changed
  AFTER UPDATE OF encrypted_password ON auth.users
  FOR EACH ROW EXECUTE FUNCTION private.on_auth_password_changed();

-- ============================================================
-- 17. Failed sign-in attempts
-- ============================================================
-- Callable before authentication, so it is the one anon-reachable surface
-- here. It is bounded on both sides: the identifier is hashed rather than
-- stored, and a hash that already has 20 rows in the last hour stops
-- accumulating. That keeps the table useful as a risk signal without letting
-- it become a write amplifier or a username directory.
-- search_path includes extensions because that is where CREATE EXTENSION puts
-- pgcrypto's digest() on Supabase; 'sha256'::text pins the digest(text, text)
-- overload. Same reasoning as _hash_verify_code in 0072.
CREATE OR REPLACE FUNCTION public.record_failed_login(p_identifier TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_hash   TEXT;
  v_recent BIGINT;
BEGIN
  IF p_identifier IS NULL OR length(btrim(p_identifier)) = 0 THEN
    RETURN;
  END IF;
  IF length(p_identifier) > 320 THEN
    RETURN;
  END IF;

  v_hash := encode(digest(lower(btrim(p_identifier)), 'sha256'::text), 'hex');

  SELECT count(*) INTO v_recent
    FROM public.login_attempts a
   WHERE a.identifier_hash = v_hash
     AND a.created_at > now() - INTERVAL '1 hour';

  IF v_recent >= 20 THEN
    RETURN;
  END IF;

  INSERT INTO public.login_attempts (identifier_hash, outcome)
  VALUES (v_hash, 'failed');
END;
$$;

REVOKE ALL ON FUNCTION public.record_failed_login(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_failed_login(TEXT) TO anon, authenticated;

-- ============================================================
-- 18. Retention
-- ============================================================
-- Attempts are a short-lived risk signal, not a record to keep. Ninety days of
-- security events is enough for a user to recognise what happened to their
-- account; devices and sessions are pruned by their own lifecycle.
CREATE OR REPLACE FUNCTION public.prune_security_telemetry()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM public.login_attempts
   WHERE created_at < now() - INTERVAL '30 days';

  DELETE FROM public.device_sessions
   WHERE revoked_at IS NOT NULL
     AND revoked_at < now() - INTERVAL '90 days';
END;
$$;

REVOKE ALL ON FUNCTION public.prune_security_telemetry()
  FROM PUBLIC, anon, authenticated;

-- security_events is append-only, so retention is enforced by a privileged
-- job rather than by the function above, which anybody could otherwise use to
-- shorten their own audit trail.

SELECT public.record_migration(
  '20260828230000',
  'device_sessions_and_security_events'
);

NOTIFY pgrst, 'reload schema';
