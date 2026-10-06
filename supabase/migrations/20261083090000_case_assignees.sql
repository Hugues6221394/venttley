-- Who a moderation case can be handed to. admin_assign_case already refuses
-- any assignee who is not active moderation staff; this lists exactly that set
-- so the console can offer a choice instead of asking for a raw user id.

CREATE OR REPLACE FUNCTION public.admin_case_assignees(p_query text DEFAULT '')
RETURNS TABLE(staff_id uuid, display_name text, username text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF NOT public.is_staff(auth.uid(),ARRAY['super_admin','admin','moderator']) THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF p_query IS NULL OR length(p_query)>50 THEN RAISE EXCEPTION 'invalid_query' USING ERRCODE='22023'; END IF;
  IF NOT public.claim_rate_limit('case_assignees_read',60,60) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  RETURN QUERY SELECT u.user_id,u.display_name::TEXT,u.anonymous_pseudonym::TEXT
  FROM public.users u
  WHERE u.user_role::TEXT IN ('super_admin','admin','moderator')
    AND public.is_staff(u.user_id,ARRAY['super_admin','admin','moderator'])
    AND (p_query='' OR starts_with(lower(u.display_name),lower(trim(p_query)))
      OR starts_with(lower(u.anonymous_pseudonym),lower(trim(p_query))))
  ORDER BY lower(u.display_name),u.user_id LIMIT 25;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_case_assignees(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_case_assignees(text) TO authenticated;

SELECT public.record_migration('20261083090000', 'case_assignees');
NOTIFY pgrst, 'reload schema';
