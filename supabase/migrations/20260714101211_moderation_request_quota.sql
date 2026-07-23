-- Production guardrails for the authenticated Tier-2 moderation endpoint.
-- The client performs Tier 1 locally; this quota protects the paid provider
-- boundary from token abuse while keeping the write path available if Tier 2
-- is degraded.

ALTER TABLE public.moderation_verdicts
  ADD COLUMN IF NOT EXISTS classifier_version TEXT NOT NULL DEFAULT 'legacy';

CREATE TABLE IF NOT EXISTS public.moderation_rate_limits (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  window_started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  request_count INT NOT NULL DEFAULT 0
    CHECK (request_count >= 0 AND request_count <= 10000)
);

ALTER TABLE public.moderation_rate_limits ENABLE ROW LEVEL SECURITY;

-- This is server-owned operational state. No mobile/admin user should read or
-- mutate it through the Data API.
REVOKE ALL ON TABLE public.moderation_rate_limits
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.moderation_rate_limits TO service_role;

CREATE OR REPLACE FUNCTION public.consume_moderation_quota(p_user UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_allowed BOOLEAN;
BEGIN
  IF p_user IS NULL THEN
    RETURN FALSE;
  END IF;

  INSERT INTO public.moderation_rate_limits (
    user_id,
    window_started_at,
    request_count
  ) VALUES (
    p_user,
    now(),
    1
  )
  ON CONFLICT (user_id) DO UPDATE
  SET
    window_started_at = CASE
      WHEN moderation_rate_limits.window_started_at <= now() - INTERVAL '1 minute'
        THEN now()
      ELSE moderation_rate_limits.window_started_at
    END,
    request_count = CASE
      WHEN moderation_rate_limits.window_started_at <= now() - INTERVAL '1 minute'
        THEN 1
      ELSE moderation_rate_limits.request_count + 1
    END
  RETURNING request_count <= 30 INTO v_allowed;

  RETURN v_allowed;
END;
$$;

REVOKE ALL ON FUNCTION public.consume_moderation_quota(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_moderation_quota(UUID)
  TO service_role;

-- New Supabase projects no longer expose tables/functions implicitly. Keep
-- the cache explicitly service-only so behavior is stable across projects.
REVOKE ALL ON TABLE public.moderation_verdicts
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.moderation_verdicts TO service_role;

NOTIFY pgrst, 'reload schema';
