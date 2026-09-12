-- Let a finished scan be run again.
--
-- Two real posts were veiled with media_labels {"reason":"scanner_not_configured"}
-- — quarantined during the window before NSFW_CLASSIFIER_URL was set. Both were
-- ordinary photos. One of them had been blurred since June.
--
-- Nothing could fix them. complete_media_scan_verdict stamps completed_at, and
-- claim_media_scan only re-leases a job where completed_at IS NULL, so a
-- verdict is final for the life of the content. That is right for a normal
-- scan — one upload, one decision, no re-rolling until you get the answer you
-- want — but it means an outage in the scanner permanently veils everything
-- uploaded during it, and a false positive has no route back.
--
-- It also leaves the brief's appeals requirement with nowhere to land: a person
-- can be told their image was refused, and there is no mechanism to look again.
--
-- So: staff can requeue. The job is cleared and the content returns to
-- 'pending', which is the state that means "not yet judged" — not 'clean',
-- because requeueing must never be a way to publish something by asking twice.
-- The next scan decides, exactly as the first one should have.

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_requeue_media_scan(
  p_kind    TEXT,
  p_id      UUID,
  p_reason  TEXT DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me    UUID := (SELECT auth.uid());
  v_found BOOLEAN := FALSE;
BEGIN
  IF NOT public.is_staff(v_me, ARRAY['super_admin', 'admin', 'moderator']) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF p_kind NOT IN ('post', 'whisper') THEN
    RAISE EXCEPTION 'invalid kind %', p_kind;
  END IF;

  -- Drop the completed job so the next claim can take a fresh lease. Deleting
  -- rather than clearing completed_at also resets the attempt counter, which
  -- would otherwise still be sitting at its cap after a scanner outage.
  DELETE FROM public.media_scan_jobs
   WHERE kind = p_kind AND content_id = p_id;

  IF p_kind = 'post' THEN
    UPDATE public.posts
       SET media_status = 'pending',
           media_labels = jsonb_build_object('reason', 'requeued'),
           -- A blocked post was soft-deleted by the 0087 trigger. Requeueing
           -- has to undo that, or the re-scan would clear a post nobody can
           -- see. Only the deletion the media verdict caused is reversed.
           deleted_at = CASE WHEN media_status = 'blocked' THEN NULL ELSE deleted_at END
     WHERE post_id = p_id;
    v_found := FOUND;
  ELSE
    UPDATE public.whispers
       SET media_status = 'pending',
           media_labels = jsonb_build_object('reason', 'requeued'),
           deleted_at = CASE WHEN media_status = 'blocked' THEN NULL ELSE deleted_at END
     WHERE whisper_id = p_id;
    v_found := FOUND;
  END IF;

  IF NOT v_found THEN
    RETURN FALSE;
  END IF;

  -- Columns are actor_id / action / target_kind / target_id / metadata; there
  -- is no reason column, so the reason travels in metadata.
  INSERT INTO public.admin_audit_log (actor_id, action, target_kind, target_id, metadata)
  VALUES (
    v_me, 'MEDIA_SCAN_REQUEUED', p_kind, p_id::TEXT,
    jsonb_build_object('reason', NULLIF(btrim(COALESCE(p_reason, '')), ''))
  );

  RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION public.admin_requeue_media_scan(TEXT, UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_requeue_media_scan(TEXT, UUID, TEXT)
  TO authenticated;

COMMENT ON FUNCTION public.admin_requeue_media_scan(TEXT, UUID, TEXT) IS
  'Staff-only: clear a completed media scan so it can run again. Returns content to pending, never to clean.';

COMMIT;

SELECT public.record_migration(
  '20260908090000', 'requeue_media_scan'
);

NOTIFY pgrst, 'reload schema';
