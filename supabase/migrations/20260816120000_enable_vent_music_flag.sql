-- Music on posts was built behind `vent_music` and dark-launched: the flag row
-- was never seeded, and both call sites read it with `fallback: false`. So the
-- composer's "Add Music" button and the story composer's music row have never
-- rendered for anyone, on any build. The feature is complete — picker, preview,
-- attachment, feed player, catalog table with RLS — it was simply switched off.
--
-- Seeding the row rather than flipping the client fallback keeps the admin
-- kill-switch meaningful: `admin_set_feature_flag('vent_music', false)` turns
-- it off again without shipping a build. The client fallback stays false, which
-- is the correct default for a flag whose row might not exist yet in a fresh
-- environment.
--
-- One flag covers every long-form composer because they are one screen:
-- Vent, Poll, Question, Testimony and Goal all route to /compose, and the
-- story composer reads the same key. Whispers are deliberately excluded —
-- a whisper is already audio, so music there is a background bed with its own
-- volume handling, not an attached track.

INSERT INTO public.feature_flags (flag_key, description, enabled, rollout_pct)
VALUES (
    'vent_music',
    'Attach a licensed music track to vents, polls, questions, testimonies, goals and 24h stories',
    TRUE,
    100
)
ON CONFLICT (flag_key) DO UPDATE
   SET enabled     = EXCLUDED.enabled,
       rollout_pct = EXCLUDED.rollout_pct,
       description = EXCLUDED.description,
       updated_at  = now();
