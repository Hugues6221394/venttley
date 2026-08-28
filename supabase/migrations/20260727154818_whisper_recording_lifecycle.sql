-- Production Whisper recording contract:
--   * 3 seconds minimum
--   * 10 minutes maximum
-- Voice effects and previews are rendered locally before upload; the database
-- still validates the authoritative duration metadata.

ALTER TABLE public.whispers
  DROP CONSTRAINT IF EXISTS whispers_audio_duration_seconds_check;

ALTER TABLE public.whispers
  ADD CONSTRAINT whispers_audio_duration_seconds_check
  CHECK (audio_duration_seconds BETWEEN 3 AND 600);

COMMENT ON COLUMN public.whispers.audio_duration_seconds IS
  'Authoritative Whisper duration in seconds; accepted range is 3..600.';
