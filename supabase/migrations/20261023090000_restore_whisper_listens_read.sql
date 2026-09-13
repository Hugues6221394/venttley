-- The Whispers rail has been failing for every signed-in member.
--
-- 20261019090000 generated its REVOKEs from a diff between a fresh deploy and
-- production and treated the fresh deploy as correct wherever they disagreed.
-- For `whisper_listens` that was backwards: production had
-- `GRANT SELECT ... TO authenticated` because two functions need it, and the
-- fresh deploy did not because nothing had ever granted it there. Revoking it
-- made both functions raise 42501 for every member.
--
--   list_unheard_whispers   "which whispers have I not heard yet"
--   whispers_for_me         the same exclusion, on the personal rail
--
-- Neither is SECURITY DEFINER, so both run as the caller and need the table
-- privilege. The client degrades rather than crashing — it logs
-- whispers.unheard_rpc_unavailable and falls back to plain recency — which is
-- why this shipped and stayed shipped: the rail still showed something. It
-- showed the wrong thing, to everyone, for four days.
--
-- Found by running the like-button test on a simulator, which printed the
-- warning in passing while testing something else entirely. No unit test could
-- have: it is a grant, and grants only exist against a real database with a
-- real role. The pgTAP suite missed it because those functions were exercised
-- as the owner, for whom no grant is needed.
--
-- Both functions only ever read the caller's own rows — `listener_id = v_me`
-- in each — so restoring the grant restores exactly what they need.
--
-- The policy is tightened at the same time, because restoring the grant alone
-- would restore something worse than the bug. `whisper listens readable` is
-- USING (true): with SELECT granted, any member could read who listened to
-- which whisper. On an app whose whole premise is that you can say something
-- without it being attached to you, a public record of who listened to what is
-- precisely the wrong thing to expose. That has been the policy since the
-- table was created; it was only ever harmless for the four days the grant was
-- missing.
--
-- Nothing needs to read another member's listens. No view touches the table —
-- counts come from elsewhere — and the only writer, record_whisper_listen, is
-- SECURITY DEFINER and unaffected.

BEGIN;

GRANT SELECT ON public.whisper_listens TO authenticated;

DROP POLICY IF EXISTS "whisper listens readable" ON public.whisper_listens;

CREATE POLICY "whisper listens are your own"
    ON public.whisper_listens
    FOR SELECT
    TO authenticated
    USING (listener_id = (SELECT auth.uid()));

COMMENT ON TABLE public.whisper_listens IS
  'Who has heard which Whisper, used only to keep the rail from repeating itself. Readable by the listener and nobody else: a public record of who listened to what would undo the anonymity the feature exists to provide. Written through record_whisper_listen (SECURITY DEFINER); members have no INSERT.';

SELECT public.record_migration(
  '20261023090000', 'restore_whisper_listens_read'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
