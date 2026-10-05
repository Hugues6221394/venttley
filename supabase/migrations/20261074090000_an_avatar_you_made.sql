-- An avatar somebody built, rather than one they picked off a shelf.
--
-- 20261064090000 added avatar_config and left a note saying the layered
-- builder would write {"kind":"custom", ...} into the same column when it
-- shipped. This is that, and the shape it actually writes is
--
--     {"kind":"custom","v":1,"skin":"s03","hair":"hair_02",
--      "hair_tint":"black","beard":null,"top":"top_01","top_tint":"white"}
--
-- hair and beard are nullable because bald is a haircut and clean-shaven is a
-- beard. skin is an id rather than a colour: the art is painted with its
-- lighting baked in, so the six tones are six files, not six tints.
--
-- Two things change here beyond the validation. First, avatar_path — the
-- studio flattens the layers to one PNG and uploads it, and every save would
-- otherwise leave the last one orphaned in the bucket forever. The function
-- hands the previous path back so the client can delete it, which is the same
-- shape set_persona_photo already uses. Second, the custom branch is checked
-- properly: until now 'custom' passed with no field checks at all, so any
-- JSONB at all could be stored under that kind.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS avatar_path TEXT;

ALTER TABLE public.personas
  ADD COLUMN IF NOT EXISTS avatar_path TEXT;

-- public.users grants SELECT column by column — migration 0003 revoked the
-- table-wide grant so recovery_key_hash and the device signature could not be
-- read — and ALTER TABLE ADD COLUMN does not inherit those grants. So
-- avatar_config has been unreadable by any client since the migration that
-- added it: writable through the definer function, and 42501 to anyone asking
-- for it back. Nothing read it until the studio needed to reopen on what
-- somebody last built, which is how it stayed invisible.
--
-- The config describes a cartoon face that is already public as an image, so
-- there is nothing here row level security was protecting. avatar_path is
-- deliberately not granted: no client needs it, and the function that does is
-- a definer.
GRANT SELECT (avatar_config) ON public.users TO authenticated;

COMMENT ON COLUMN public.users.avatar_path IS
  'Storage path of the flattened avatar this account last uploaded, so the '
  'next save can delete it. Null for a preset, which is a shared file nobody '
  'may delete, and null for an uploaded photograph, which set_profile_photo '
  'tracks separately.';

-- The return type changes from JSONB to TEXT, which CREATE OR REPLACE will not
-- do. Dropped by its old signature so the new four-argument one can be made;
-- the fourth argument has a default, so a client still running the previous
-- build keeps resolving to it with its three named arguments.
DROP FUNCTION IF EXISTS public.set_avatar_config(JSONB, TEXT, UUID);

-- OR REPLACE so re-applying this file is a no-op rather than an error: the
-- drop above only names the old three-argument signature, and a second run
-- would otherwise collide with the four-argument one it created itself.
CREATE OR REPLACE FUNCTION public.set_avatar_config(
  p_config      JSONB,
  p_photo_url   TEXT DEFAULT NULL,
  p_persona_id  UUID DEFAULT NULL,
  p_avatar_path TEXT DEFAULT NULL
)
RETURNS TEXT
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
  v_prev TEXT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  -- Shape-checked here rather than trusted from the client: this is a JSONB
  -- column and literally anything would otherwise fit in it.
  IF p_config IS NULL OR v_kind IS NULL OR v_kind NOT IN ('preset', 'custom') THEN
    RAISE EXCEPTION 'invalid_avatar_config';
  END IF;

  -- A ceiling before the field checks, so a megabyte of JSON is refused
  -- cheaply rather than regex-matched first.
  IF length(p_config::TEXT) > 1000 THEN
    RAISE EXCEPTION 'invalid_avatar_config';
  END IF;

  IF v_kind = 'preset' THEN
    IF COALESCE(p_config ->> 'preset', '') !~ '^a[0-9]{2}$' THEN
      RAISE EXCEPTION 'invalid_avatar_preset';
    END IF;
  ELSE
    -- ->> yields NULL for a JSON null, which is what nullable means here: a
    -- missing key and an explicit null both read as "no hair".
    IF COALESCE(p_config ->> 'skin', '') !~ '^s[0-9]{2}$' THEN
      RAISE EXCEPTION 'invalid_avatar_skin';
    END IF;
    IF COALESCE(p_config ->> 'top', '') !~ '^top_[0-9]{2}$' THEN
      RAISE EXCEPTION 'invalid_avatar_top';
    END IF;
    IF p_config ->> 'hair' IS NOT NULL
       AND p_config ->> 'hair' !~ '^hair_[0-9]{2}$' THEN
      RAISE EXCEPTION 'invalid_avatar_hair';
    END IF;
    IF p_config ->> 'beard' IS NOT NULL
       AND p_config ->> 'beard' !~ '^beard_[0-9]{2}$' THEN
      RAISE EXCEPTION 'invalid_avatar_beard';
    END IF;
    IF COALESCE(p_config ->> 'hair_tint', '') !~ '^[a-z]{3,12}$'
       OR COALESCE(p_config ->> 'top_tint', '') !~ '^[a-z]{3,12}$' THEN
      RAISE EXCEPTION 'invalid_avatar_tint';
    END IF;
  END IF;

  -- The path is written by the app, so it is checked rather than trusted: it
  -- must sit under this account's own prefix. Otherwise a caller could name
  -- somebody else's object and have the next save delete it.
  IF p_avatar_path IS NOT NULL
     AND p_avatar_path !~ ('^' || v_me::TEXT || '/[A-Za-z0-9._-]{1,120}$') THEN
    RAISE EXCEPTION 'invalid_avatar_path';
  END IF;

  IF p_persona_id IS NULL THEN
    SELECT avatar_path INTO v_prev FROM public.users WHERE user_id = v_me;
    UPDATE public.users
       SET avatar_config = p_config,
           profile_photo_url = COALESCE(p_photo_url, profile_photo_url),
           avatar_path = p_avatar_path,
           updated_at = now()
     WHERE user_id = v_me;
  ELSE
    SELECT avatar_path INTO v_prev
      FROM public.personas
     WHERE persona_id = p_persona_id AND user_id = v_me AND deleted_at IS NULL;
    UPDATE public.personas
       SET avatar_config = p_config,
           profile_photo_url = COALESCE(p_photo_url, profile_photo_url),
           avatar_path = p_avatar_path
     WHERE persona_id = p_persona_id AND user_id = v_me AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'persona not found'; END IF;
  END IF;

  -- Null when there was nothing to clean up, and never the path just written.
  RETURN NULLIF(v_prev, COALESCE(p_avatar_path, ''));
END $$;

REVOKE ALL ON FUNCTION public.set_avatar_config(JSONB, TEXT, UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_avatar_config(JSONB, TEXT, UUID, TEXT)
  TO authenticated, service_role;

SELECT public.record_migration('20261074090000', 'an_avatar_you_made');

NOTIFY pgrst, 'reload schema';
