-- Harden push-token teardown and give global sign-out an owner-scoped way to
-- stop delivery to every device before Supabase Auth revokes the sessions.

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
  v_window_started_at TIMESTAMPTZ;
  v_counter INT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF length(COALESCE(p_token, '')) NOT BETWEEN 16 AND 4096
     OR p_token ~ '[[:space:][:cntrl:]]' THEN
    RAISE EXCEPTION 'invalid_push_token';
  END IF;
  IF p_platform NOT IN ('android', 'ios', 'web') THEN
    RAISE EXCEPTION 'invalid platform';
  END IF;

  -- Serialize the first quota row and token-cap mutation for this account.
  -- This closes the absent-row race without blocking unrelated users.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('push_register:' || v_me::TEXT, 0)
  );

  SELECT rate.window_started_at, rate.counter
    INTO v_window_started_at, v_counter
    FROM public.rate_limits AS rate
   WHERE rate.user_id = v_me
     AND rate.action_key = 'register_push_token'
   FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.rate_limits (
      user_id, action_key, window_started_at, counter
    ) VALUES (
      v_me, 'register_push_token', now(), 1
    );
  ELSIF v_window_started_at <= now() - INTERVAL '1 minute' THEN
    UPDATE public.rate_limits
       SET window_started_at = now(), counter = 1
     WHERE user_id = v_me
       AND action_key = 'register_push_token';
  ELSIF v_counter >= 20 THEN
    RAISE EXCEPTION 'rate_limited';
  ELSE
    UPDATE public.rate_limits
       SET counter = counter + 1
     WHERE user_id = v_me
       AND action_key = 'register_push_token';
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

  -- A hostile client cannot grow fanout work without bound. Ten active
  -- installations leaves ample room for legitimate phones/tablets and token
  -- rotations while capping storage and per-event delivery amplification.
  DELETE FROM public.push_tokens AS stale
  USING (
    SELECT token
      FROM public.push_tokens
     WHERE user_id = v_me
     ORDER BY last_seen_at DESC, created_at DESC, token DESC
     OFFSET 10
  ) AS overflow
  WHERE stale.user_id = v_me
    AND stale.token = overflow.token;
END;
$$;

REVOKE ALL ON FUNCTION public.register_push_token(TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_push_token(TEXT, TEXT, TEXT, TEXT)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.unregister_push_token(p_token TEXT)
RETURNS VOID
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

  DELETE FROM public.push_tokens
   WHERE user_id = v_me
     AND token = p_token;
END;
$$;

REVOKE ALL ON FUNCTION public.unregister_push_token(TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unregister_push_token(TEXT)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.unregister_all_push_tokens()
RETURNS INT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_deleted INT := 0;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  DELETE FROM public.push_tokens
   WHERE user_id = v_me;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.unregister_all_push_tokens()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unregister_all_push_tokens()
  TO authenticated;

NOTIFY pgrst, 'reload schema';
