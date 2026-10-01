-- An avatar somebody chose, rather than the first letter of their name.
--
-- Until now an avatar was a letter on a colour derived from a hash of a seed.
-- "W on teal" is not recognisably a person, and it is the first thing anybody
-- sees beside every vent in the feed.
--
-- Two columns and one function, and deliberately no view change. The avatar a
-- reader sees in a feed, a comment or a chat row is already resolved through
-- profile_photo_url, so choosing a preset points that at a shared file and
-- every surface in the app shows it without being touched. Rewriting
-- feed_posts to carry a second avatar column would mean reissuing a view that
-- eight other things read — and the last time that view was reissued it
-- silently lost WITH (security_invoker = true), which turns row level security
-- off for every one of them.
--
-- The config column holds intent rather than a filename, which is what makes
-- the layered builder free later. Today the only shape is
--
--     {"kind": "preset", "preset": "a07"}
--
-- and when the builder ships it writes
--
--     {"kind": "custom", "base": "masc_01", "skin": "03", "hair": "fem_04",
--      "top": "02", "facial_hair": null, "glasses": "01"}
--
-- into the same column. Nobody's avatar gets migrated.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS avatar_config JSONB;

ALTER TABLE public.personas
  ADD COLUMN IF NOT EXISTS avatar_config JSONB;

COMMENT ON COLUMN public.users.avatar_config IS
  'How to draw this account''s avatar. {"kind":"preset","preset":"a07"} today, '
  '{"kind":"custom",...} once the layered builder ships. Null falls back to the '
  'generated avatar_seed, so an account that never chooses still renders.';

CREATE OR REPLACE FUNCTION public.set_avatar_config(
  p_config     JSONB,
  p_photo_url  TEXT DEFAULT NULL,
  p_persona_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
-- Definer, because authenticated has no UPDATE on users by design — every
-- write to that table goes through a function like this one. Safe here for the
-- reason that matters: the only rows this can touch are keyed by auth.uid(),
-- so the caller cannot name somebody else's. Unlike a function that has to
-- *read* content, there is nothing here that row level security was deciding.
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me   UUID := (SELECT auth.uid());
  v_kind TEXT := p_config ->> 'kind';
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  -- Shape-checked here rather than trusted from the client: this is a JSONB
  -- column and literally anything would otherwise fit in it.
  IF p_config IS NULL OR v_kind IS NULL OR v_kind NOT IN ('preset', 'custom') THEN
    RAISE EXCEPTION 'invalid_avatar_config';
  END IF;
  IF v_kind = 'preset'
     AND COALESCE(p_config ->> 'preset', '') !~ '^a[0-9]{2}$' THEN
    RAISE EXCEPTION 'invalid_avatar_preset';
  END IF;

  IF p_persona_id IS NULL THEN
    UPDATE public.users
       SET avatar_config = p_config,
           profile_photo_url = COALESCE(p_photo_url, profile_photo_url),
           updated_at = now()
     WHERE user_id = v_me;
  ELSE
    UPDATE public.personas
       SET avatar_config = p_config,
           profile_photo_url = COALESCE(p_photo_url, profile_photo_url)
     WHERE persona_id = p_persona_id AND user_id = v_me AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'persona not found'; END IF;
  END IF;

  RETURN p_config;
END $$;

REVOKE ALL ON FUNCTION public.set_avatar_config(JSONB, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_avatar_config(JSONB, TEXT, UUID)
  TO authenticated, service_role;

SELECT public.record_migration('20261064090000', 'an_avatar_you_chose');

NOTIFY pgrst, 'reload schema';
