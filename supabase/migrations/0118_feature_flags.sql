-- 0118: Make the existing feature_flags table (0022) a real remote-config
-- system: deterministic percentage rollouts, one-call client evaluation,
-- realtime flag flips, and an audited admin write RPC.
--
-- Rollout is deterministic per user: hashtext(uid || key) buckets each
-- user into 0..99, so a user stays in (or out of) a rollout as the
-- percentage grows — no flapping between sessions.

-- Clients need read access for the realtime channel + fallback reads.
ALTER TABLE public.feature_flags ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.feature_flags FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.feature_flags FROM authenticated;
GRANT SELECT ON TABLE public.feature_flags TO authenticated;
DROP POLICY IF EXISTS feature_flags_read ON public.feature_flags;
CREATE POLICY feature_flags_read ON public.feature_flags
  FOR SELECT TO authenticated USING (TRUE);

-- Deterministic evaluation for the calling user, one round trip.
CREATE OR REPLACE FUNCTION public.my_feature_flags()
RETURNS TABLE (flag_key TEXT, enabled BOOLEAN, payload JSONB)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$
  SELECT
    f.flag_key,
    f.enabled AND (
      f.rollout_pct >= 100
      OR (abs(hashtext(coalesce(auth.uid()::text, '') || f.flag_key)) % 100)
         < f.rollout_pct
    ) AS enabled,
    f.metadata AS payload
  FROM public.feature_flags f;
$$;

REVOKE ALL ON FUNCTION public.my_feature_flags() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_feature_flags() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_feature_flag(
  p_key TEXT,
  p_enabled BOOLEAN,
  p_rollout_pct INT DEFAULT 100,
  p_metadata JSONB DEFAULT '{}'::jsonb,
  p_description TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()), ARRAY['super_admin','admin']) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  INSERT INTO public.feature_flags (flag_key, enabled, rollout_pct, metadata, description, updated_by, updated_at)
  VALUES (p_key, p_enabled, LEAST(GREATEST(p_rollout_pct, 0), 100), p_metadata, p_description, (SELECT auth.uid()), NOW())
  ON CONFLICT (flag_key) DO UPDATE SET
    enabled = EXCLUDED.enabled,
    rollout_pct = EXCLUDED.rollout_pct,
    metadata = EXCLUDED.metadata,
    description = COALESCE(EXCLUDED.description, feature_flags.description),
    updated_by = (SELECT auth.uid()),
    updated_at = NOW();
  PERFORM public.admin_log('feature_flag.set', 'feature_flag', NULL, p_key,
    NULL, jsonb_build_object('enabled', p_enabled, 'rollout_pct', p_rollout_pct),
    NULL, '{}'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_feature_flag(TEXT, BOOLEAN, INT, JSONB, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_feature_flag(TEXT, BOOLEAN, INT, JSONB, TEXT)
  TO authenticated;

-- Live flag flips for running apps.
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.feature_flags;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Seed the rollout-ready flags for upcoming work (shipped features stay on
-- via their existing 0022 rows).
INSERT INTO public.feature_flags (flag_key, enabled, rollout_pct, description) VALUES
  ('voice_filters',    FALSE, 0, 'Voice-changing filters on whisper recording'),
  ('new_feed_ranking', FALSE, 0, 'Next-gen personal feed ranking experiment'),
  ('beta_communities', FALSE, 0, 'Experimental community formats')
ON CONFLICT (flag_key) DO NOTHING;
