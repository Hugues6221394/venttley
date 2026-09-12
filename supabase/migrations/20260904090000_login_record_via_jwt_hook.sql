-- Record every sign-in inside GoTrue, on the free plan.
--
-- 20260903090000 put login recording and brute-force throttling in a
-- password_verification_attempt hook. That hook turns out to be Team plan and
-- above, so on this project it can never run. The function stays — it is
-- correct and costs nothing sitting there — but nothing calls it.
--
-- The Customize Access Token (JWT) Claims hook IS available on the free plan,
-- and it fires inside GoTrue for every token this project issues, from any
-- client. That is enough to close the more serious of the two findings:
-- signing in straight against the API used to create no record at all, because
-- the entire risk pipeline lived in the Flutter client and the anon key ships
-- inside the app. Now the database writes the record itself, and a login from
-- something that is not the app still lands in the account holder's security
-- history.
--
-- WHAT THIS DOES NOT DO
--
-- It cannot throttle brute force. It only runs when a password was already
-- accepted, so it never sees a failure. Wrong-password flooding has to be
-- stopped by Supabase's own auth rate limits and CAPTCHA (Authentication →
-- Rate Limits, Authentication → Attack Protection), both free, both in front
-- of GoTrue where the failures actually happen.
--
-- REFRESHES ARE NOT LOGINS
--
-- This hook also fires every time an access token is refreshed, roughly hourly
-- per active session. Writing an event each time would bury the real sign-ins
-- under noise and make the security history useless — which is worse than not
-- having it. Each session is recorded once, on the first token issued for it.
--
-- THIS RUNS ON THE CRITICAL PATH OF EVERY LOGIN
--
-- If this function raises, GoTrue fails the request and nobody can sign in or
-- refresh. So every path returns the claims it was given, unchanged, and the
-- whole body is wrapped so that any error still returns them. Recording a
-- login is worth doing; it is not worth an outage.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Which sessions we have already recorded
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.auth_session_seen (
  session_id    UUID PRIMARY KEY,
  user_id       UUID NOT NULL,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE private.auth_session_seen IS
  'One row per auth session, so the JWT hook records a sign-in once instead of on every token refresh.';

CREATE INDEX IF NOT EXISTS auth_session_seen_user_idx
  ON private.auth_session_seen (user_id, first_seen_at DESC);

ALTER TABLE private.auth_session_seen ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.auth_session_seen FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The hook
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event JSONB)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_claims  JSONB;
  v_user    UUID;
  v_session UUID;
  v_method  TEXT;
  v_country TEXT;
  v_rows    INT := 0;
BEGIN
  -- Read this first and return it on every path. Whatever else happens, the
  -- token must come out the way GoTrue expects it.
  v_claims := COALESCE(event->'claims', '{}'::JSONB);

  v_user    := NULLIF(event->>'user_id', '')::UUID;
  v_session := NULLIF(v_claims->>'session_id', '')::UUID;
  v_method  := COALESCE(event->>'authentication_method', '');

  IF v_user IS NULL OR v_session IS NULL THEN
    RETURN jsonb_build_object('claims', v_claims);
  END IF;

  -- An auth identity with no profile row yet is mid-signup; the foreign keys
  -- on the tables below would reject it, so leave it alone.
  IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.user_id = v_user) THEN
    RETURN jsonb_build_object('claims', v_claims);
  END IF;

  -- First token for this session? ON CONFLICT DO NOTHING is what makes this
  -- safe under concurrency: two tokens issued at once cannot both win, so the
  -- sign-in is recorded exactly once.
  INSERT INTO private.auth_session_seen (session_id, user_id)
  VALUES (v_session, v_user)
  ON CONFLICT (session_id) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    -- Already recorded: this is a refresh, not a new sign-in.
    RETURN jsonb_build_object('claims', v_claims);
  END IF;

  SELECT u.last_country INTO v_country
    FROM public.users u WHERE u.user_id = v_user;

  INSERT INTO public.login_attempts (user_id, outcome, country)
  VALUES (v_user, 'success', v_country);

  INSERT INTO public.security_events (user_id, kind, severity, context)
  VALUES (
    v_user, 'login', 'info',
    jsonb_build_object(
      'source', 'auth_hook',
      'method', NULLIF(v_method, ''),
      'country', v_country
    )
  );

  RETURN jsonb_build_object('claims', v_claims);

EXCEPTION WHEN OTHERS THEN
  -- Never break sign-in. Returning the untouched claims means the worst case
  -- is a missing history entry, not a user who cannot get into their account.
  RETURN jsonb_build_object('claims', COALESCE(event->'claims', '{}'::JSONB));
END $$;

COMMENT ON FUNCTION public.custom_access_token_hook(JSONB) IS
  'GoTrue Customize Access Token hook: records each sign-in once, server-side. Returns claims unmodified. Enable in Authentication > Hooks.';

REVOKE ALL ON FUNCTION public.custom_access_token_hook(JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(JSONB)
  TO supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- 3. Housekeeping
-- ---------------------------------------------------------------------------

-- The dedupe table only needs to remember a session while it can still issue
-- tokens. Anything older than a refresh-token lifetime is dead weight.
CREATE OR REPLACE FUNCTION private.prune_auth_session_seen(p_older_than_days INT DEFAULT 90)
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_removed INT;
BEGIN
  DELETE FROM private.auth_session_seen
   WHERE first_seen_at < now() - make_interval(days => GREATEST(p_older_than_days, 1));
  GET DIAGNOSTICS v_removed = ROW_COUNT;
  RETURN v_removed;
END $$;

REVOKE ALL ON FUNCTION private.prune_auth_session_seen(INT)
  FROM PUBLIC, anon, authenticated;

COMMIT;

SELECT public.record_migration(
  '20260904090000', 'login_record_via_jwt_hook'
);

NOTIFY pgrst, 'reload schema';
