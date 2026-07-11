-- ---------------------------------------------------------------------------
-- Venttly | Migration 0074 — Reconcile whisper plays_count to real listens
-- ---------------------------------------------------------------------------
-- 0073 zeroed the demo whispers whose id starts with 'f0000000-'. But other
-- rows (older test/seed whispers with different ids) still carry fabricated
-- plays_count values — that is the "2.7k" a fresh user still sees on Home.
--
-- The single source of truth for how many people listened is the
-- whisper_listens table (one row per distinct listener, created in 0073).
-- This migration rebuilds EVERY whisper's plays_count from that table, so the
-- public number can never again be anything other than the real listener
-- count. record_whisper_listen() keeps it in sync from here on.
-- ---------------------------------------------------------------------------

UPDATE public.whispers w
   SET plays_count = COALESCE(
         (SELECT count(*)
            FROM public.whisper_listens l
           WHERE l.whisper_id = w.whisper_id),
         0)
 WHERE w.plays_count <> COALESCE(
         (SELECT count(*)
            FROM public.whisper_listens l
           WHERE l.whisper_id = w.whisper_id),
         0);

NOTIFY pgrst, 'reload schema';
