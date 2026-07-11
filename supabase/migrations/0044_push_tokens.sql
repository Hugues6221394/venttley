-- 0044_push_tokens.sql
--
-- Foundation for OS-level push notifications. Stores per-device FCM
-- (Android) and APNs (iOS) tokens against the authenticated user so a
-- Supabase Edge Function can fan out pushes on new chat messages, new
-- friend requests, and new notifications.
--
-- See docs/notifications.md for the full server-side setup steps.

CREATE TABLE IF NOT EXISTS public.push_tokens (
    user_id     UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    platform    TEXT NOT NULL CHECK (platform IN ('android', 'ios', 'web')),
    token       TEXT NOT NULL,
    locale      TEXT,
    app_version TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, token)
);

CREATE INDEX IF NOT EXISTS push_tokens_user_idx
    ON public.push_tokens (user_id);

ALTER TABLE public.push_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "push tokens self read" ON public.push_tokens;
CREATE POLICY "push tokens self read"
    ON public.push_tokens FOR SELECT
    USING (user_id = auth.uid());

GRANT SELECT ON public.push_tokens TO authenticated;

CREATE OR REPLACE FUNCTION public.register_push_token(
    p_token       TEXT,
    p_platform    TEXT,
    p_locale      TEXT DEFAULT NULL,
    p_app_version TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_token IS NULL OR length(p_token) = 0 THEN
        RAISE EXCEPTION 'token required';
    END IF;
    IF p_platform NOT IN ('android', 'ios', 'web') THEN
        RAISE EXCEPTION 'invalid platform';
    END IF;

    INSERT INTO push_tokens (user_id, platform, token, locale, app_version)
    VALUES (v_me, p_platform, p_token, p_locale, p_app_version)
    ON CONFLICT (user_id, token) DO UPDATE
       SET platform     = EXCLUDED.platform,
           locale       = EXCLUDED.locale,
           app_version  = EXCLUDED.app_version,
           last_seen_at = now();
END $$;

REVOKE ALL ON FUNCTION public.register_push_token(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_push_token(TEXT, TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.unregister_push_token(p_token TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_me UUID := auth.uid();
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    DELETE FROM push_tokens WHERE user_id = v_me AND token = p_token;
END $$;

REVOKE ALL ON FUNCTION public.unregister_push_token(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unregister_push_token(TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
