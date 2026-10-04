-- Members only ever read global, active, sent, unexpired broadcasts.
-- Independent of approval rollout: rollback must not reopen audience leakage.
BEGIN;
DROP POLICY IF EXISTS "broadcasts public read" ON public.broadcasts;
CREATE POLICY "broadcasts public read" ON public.broadcasts FOR SELECT TO anon,authenticated
USING (
 audience='{"scope":"all"}'::JSONB AND is_active
 AND sent_at IS NOT NULL AND sent_at<=now()
 AND (scheduled_for IS NULL OR scheduled_for<=now())
 AND (expires_at IS NULL OR expires_at>now())
);
-- Retain existing staff-inspection rights. A later permissive policy cannot
-- accidentally expose targeted, unpublished, future or expired messages.
CREATE POLICY "broadcast visibility boundary" ON public.broadcasts AS RESTRICTIVE FOR SELECT TO anon,authenticated
USING (
 (SELECT public.is_staff((SELECT auth.uid()),ARRAY['super_admin','admin','moderator','read_only_auditor']))
 OR (audience='{"scope":"all"}'::JSONB AND is_active
   AND sent_at IS NOT NULL AND sent_at<=now()
   AND (scheduled_for IS NULL OR scheduled_for<=now())
   AND (expires_at IS NULL OR expires_at>now()))
);
COMMIT;
