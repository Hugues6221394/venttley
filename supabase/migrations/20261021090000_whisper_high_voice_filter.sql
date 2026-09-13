-- =========================================================================
-- A higher voice, and a CHECK that was quietly a feature flag
--
-- Two things, one migration.
--
-- Reported from the device: the Soft filter sounds identical to Original, and
-- there is no option that raises pitch — every disguise in the list either
-- lowers it (Deep, Dark, Anonymous) or changes timbre without moving pitch at
-- all (Robot, Echo, Synth). For anyone whose voice already sits high, the
-- available disguises all push toward a register that does not hide them.
--
-- The client fix is in whisper_voice_processor.dart. This migration is the
-- half that has to land first: whispers.voice_filter carries a CHECK listing
-- the eight filters 0042 shipped with, so a ninth is rejected by the database
-- no matter what the app offers. A constraint enumerating product options is a
-- feature flag wearing a data-integrity costume — it is the right call for a
-- closed set, but it means the set cannot grow without coming through here.
--
-- 'high_voice' is named to mirror 'deep_voice' rather than after who might
-- want it. The pairing is what makes it discoverable in a row of chips, and a
-- filter named for a kind of person would age badly in a product whose whole
-- premise is that nobody has to say who they are.
-- =========================================================================

ALTER TABLE public.whispers
  DROP CONSTRAINT IF EXISTS whispers_voice_filter_check;

ALTER TABLE public.whispers
  ADD CONSTRAINT whispers_voice_filter_check
  CHECK (
    voice_filter IS NULL
    OR voice_filter IN (
      'none', 'deep_voice', 'high_voice', 'robot',
      'echo', 'synth', 'soft', 'dark', 'anonymous'
    )
  );

COMMENT ON COLUMN public.whispers.voice_filter IS
  'Which disguise was applied before upload. The audio is already processed by the time it is stored — this records which one, it does not select one at playback. Adding a filter means widening this CHECK as well as the client, which is deliberate: the set is closed on purpose.';

SELECT public.record_migration(
  '20261021090000', 'whisper_high_voice_filter'
);

NOTIFY pgrst, 'reload schema';
