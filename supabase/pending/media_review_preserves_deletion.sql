-- UNAPPLIED SECURITY DRAFT. Preserve existing RPC signature; no data rewrite.
-- Requires current_auth_session_id and require_aal2 from existing hardening.
BEGIN;
CREATE OR REPLACE FUNCTION public.admin_set_media_status(p_kind TEXT,p_id UUID,p_status TEXT,p_reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor UUID:=auth.uid(); deleted TIMESTAMPTZ; previous TEXT;
BEGIN
 IF NOT public.is_staff(actor,ARRAY['super_admin','admin','moderator']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
 PERFORM private.require_aal2();
 IF NOT EXISTS(SELECT 1 FROM auth.sessions WHERE id=private.current_auth_session_id() AND user_id=actor
   AND aal::TEXT='aal2' AND (not_after IS NULL OR not_after>clock_timestamp())) THEN RAISE EXCEPTION 'session_unavailable'; END IF;
 IF p_id IS NULL OR p_kind IS NULL OR p_kind NOT IN ('post','whisper') OR p_status IS NULL
   OR p_status NOT IN ('clean','pending','sensitive','blocked') OR length(p_reason)>500 THEN RAISE EXCEPTION 'invalid_input'; END IF;
 IF NOT public.claim_rate_limit('admin_media_review',60,30) THEN RAISE EXCEPTION 'rate_limited'; END IF;
 PERFORM 1 FROM public.users WHERE user_id=actor FOR SHARE;
 IF NOT public.is_staff(actor,ARRAY['super_admin','admin','moderator']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
 IF p_kind='post' THEN
   SELECT deleted_at,media_status INTO deleted,previous FROM public.posts WHERE post_id=p_id FOR UPDATE;
 ELSE
   SELECT deleted_at,media_status INTO deleted,previous FROM public.whispers WHERE whisper_id=p_id FOR UPDATE;
 END IF;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
 IF deleted IS NOT NULL AND p_status='clean' THEN RAISE EXCEPTION 'content_deleted_use_restore_workflow'; END IF;
 -- Same-state retries cannot create additional audit/engagement records.
 IF previous=p_status THEN RETURN; END IF;
 -- Visibility of content and safety of an image are separate decisions.
 -- Never clear deleted_at as a side effect of classifying media.
 IF p_kind='post' THEN UPDATE public.posts SET media_status=p_status WHERE post_id=p_id;
 ELSE UPDATE public.whispers SET media_status=p_status WHERE whisper_id=p_id; END IF;
 PERFORM public.admin_log('media.set_status',p_kind,p_id,NULL,
   jsonb_build_object('media_status',previous),jsonb_build_object('media_status',p_status),p_reason,'{}');
END $$;
REVOKE ALL ON FUNCTION public.admin_set_media_status(TEXT,UUID,TEXT,TEXT) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_media_status(TEXT,UUID,TEXT,TEXT) TO authenticated;
COMMIT;
