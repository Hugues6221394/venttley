-- Taking a music track down, putting it back, and changing when its rights end.
--
-- Members only ever read active tracks whose rights have not expired
-- (music_tracks_enabled_read), so deactivating a track or moving its expiry
-- into the past silences it everywhere at once, including on Vents and
-- Whispers that already carry it. Nothing is deleted: putting it back restores
-- every attachment. Adding tracks stays with the provider import.
BEGIN;

CREATE FUNCTION public.admin_set_music_track(p_operation UUID, p_track UUID, p_active BOOLEAN,
  p_rights_expires_at TIMESTAMPTZ, p_reason TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  actor   UUID := auth.uid();
  before  public.music_tracks%ROWTYPE;
  request JSONB := jsonb_build_object('track', p_track, 'active', p_active, 'expires', p_rights_expires_at, 'reason', p_reason);
BEGIN
  IF NOT public.is_staff(actor, ARRAY['super_admin','admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  PERFORM private.require_aal2();
  IF p_operation IS NULL OR p_track IS NULL OR p_active IS NULL
     OR p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 500 THEN
    RAISE EXCEPTION 'invalid_input';
  END IF;
  IF private.admin_operation_existing(actor, p_operation, 'music.set_track', request) IS NOT NULL THEN RETURN; END IF;
  IF NOT public.claim_rate_limit('admin_music_track', 3600, 60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  SELECT * INTO before FROM public.music_tracks WHERE track_id = p_track FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
  IF p_active AND p_rights_expires_at IS NOT NULL AND p_rights_expires_at <= now() THEN
    RAISE EXCEPTION 'rights_expired';
  END IF;
  IF before.is_active = p_active AND before.rights_expires_at IS NOT DISTINCT FROM p_rights_expires_at THEN
    RAISE EXCEPTION 'no_change';
  END IF;

  UPDATE public.music_tracks SET is_active = p_active, rights_expires_at = p_rights_expires_at, updated_at = now()
   WHERE track_id = p_track;
  PERFORM private.record_admin_operation(actor, p_operation, 'music.set_track', request, p_track);
  PERFORM private.record_operational_audit(actor,
    CASE WHEN before.is_active AND NOT p_active THEN 'music.track_taken_down'
         WHEN NOT before.is_active AND p_active THEN 'music.track_restored'
         ELSE 'music.track_rights_changed' END,
    'music_track', p_track, left(before.title || ' · ' || before.artist, 200), btrim(p_reason),
    jsonb_build_object('was_active', before.is_active, 'active', p_active,
                       'rights_expired_at_before', before.rights_expires_at, 'rights_expire_at', p_rights_expires_at));
END $$;
REVOKE ALL ON FUNCTION public.admin_set_music_track(UUID,UUID,BOOLEAN,TIMESTAMPTZ,TEXT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_music_track(UUID,UUID,BOOLEAN,TIMESTAMPTZ,TEXT) TO authenticated;

SELECT public.record_migration('20261091090000', 'music_track_controls');
COMMIT;
