-- Background music under a whisper.
--
-- A whisper is already audio, so music here is not an attached track the way it
-- is on a vent — it is a bed playing *underneath* a voice. That difference
-- drives every decision below.
--
-- 1. THE VOLUME CEILING IS A SERVER CONSTRAINT, NOT A SLIDER RANGE.
--    Posts allow music_volume up to 1.0 because nothing competes with it. A
--    whisper's whole purpose is someone's voice; a bed at 0.8 buries it, and on
--    this platform the thing being buried is usually the hardest thing the
--    person had to say. The ceiling is 0.35 and it is enforced by a CHECK
--    constraint and re-checked in the RPC, so a client bug or a crafted request
--    cannot produce a whisper you cannot hear.
--
-- 2. NO music_duration_ms.
--    A post's music is a 3-30s window. A bed loops for however long the whisper
--    runs, so a duration would be meaningless — the client loops from
--    music_start_ms until the voice ends.
--
-- 3. STILL A REFERENCE, NEVER A FILE.
--    Nothing here stores or mixes audio. The recorded whisper is untouched and
--    the bed is streamed from the track's authorised preview at playback time.
--    Mixing the two into one uploaded file would mean downloading a full
--    commercial track to the device, which the licensing architecture
--    explicitly forbids, and would bake a choice the author can no longer undo.

ALTER TABLE public.whispers
  ADD COLUMN IF NOT EXISTS music_track_id UUID
    REFERENCES public.music_tracks(track_id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS music_start_ms INT,
  ADD COLUMN IF NOT EXISTS music_volume REAL;

ALTER TABLE public.whispers
  DROP CONSTRAINT IF EXISTS whispers_music_bed_check;
ALTER TABLE public.whispers
  ADD CONSTRAINT whispers_music_bed_check CHECK (
    (music_track_id IS NULL
      AND music_start_ms IS NULL
      AND music_volume IS NULL)
    OR
    (music_track_id IS NOT NULL
      AND music_start_ms BETWEEN 0 AND 60000
      -- Ceiling, not a preference. See note 1.
      AND music_volume BETWEEN 0.0 AND 0.35)
  );

CREATE INDEX IF NOT EXISTS whispers_music_track_idx
  ON public.whispers (music_track_id)
  WHERE music_track_id IS NOT NULL;

-- New columns need explicit Data API privileges on current Supabase projects.
GRANT SELECT (
  music_track_id, music_start_ms, music_volume
) ON public.whispers TO anon, authenticated;

-- Mirrors public.set_post_music: same auth check, same rate-limit bucket, same
-- ownership rule, same "pass NULL to clear" contract. Kept as its own RPC
-- rather than folded into create_whisper_idempotent, which is a hardened
-- trust-boundary function that should not be rewritten to add an optional
-- field.
CREATE OR REPLACE FUNCTION public.set_whisper_music(
  p_whisper_id UUID,
  p_music_track_id UUID,
  p_start_ms INT DEFAULT 0,
  p_volume REAL DEFAULT 0.18
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_author UUID;
  v_track_duration INT;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  IF NOT private.claim_music_quota(v_me, 'music_attachment', 30) THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;

  SELECT whisper.author_id INTO v_author
    FROM public.whispers AS whisper
   WHERE whisper.whisper_id = p_whisper_id
     AND whisper.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'whisper not found'; END IF;
  IF v_author <> v_me THEN RAISE EXCEPTION 'not your whisper'; END IF;

  IF p_music_track_id IS NULL THEN
    UPDATE public.whispers
       SET music_track_id = NULL,
           music_start_ms = NULL,
           music_volume = NULL
     WHERE whisper_id = p_whisper_id;
    RETURN TRUE;
  END IF;

  IF NOT private.feature_enabled_for('vent_music', v_me) THEN
    RAISE EXCEPTION 'music_feature_disabled';
  END IF;

  SELECT track.duration_ms INTO v_track_duration
    FROM public.music_tracks AS track
   WHERE track.track_id = p_music_track_id
     AND track.is_active
     AND (track.rights_expires_at IS NULL OR track.rights_expires_at > now());
  IF NOT FOUND THEN RAISE EXCEPTION 'music_track_unavailable'; END IF;

  -- The bed loops, so start_ms only has to land inside the track. The volume
  -- ceiling is re-checked here and not left to the CHECK constraint alone, so
  -- the caller gets a named error instead of a constraint violation.
  IF p_start_ms < 0 OR p_start_ms >= v_track_duration THEN
    RAISE EXCEPTION 'invalid_music_window';
  END IF;
  IF p_volume IS NULL OR p_volume < 0.0 OR p_volume > 0.35 THEN
    RAISE EXCEPTION 'music_volume_out_of_range';
  END IF;

  UPDATE public.whispers
     SET music_track_id = p_music_track_id,
         music_start_ms = p_start_ms,
         music_volume = p_volume
   WHERE whisper_id = p_whisper_id;
  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.set_whisper_music(UUID, UUID, INT, REAL)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_whisper_music(UUID, UUID, INT, REAL)
  TO authenticated;
