-- The feed views may read this cache as their owner, but clients should not
-- query the materialized view directly. Expose only the small role-checked
-- health probe used by the Super Admin console.
REVOKE SELECT ON public.mv_hot_posts FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_hot_feed_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  caller_id UUID := (SELECT auth.uid());
BEGIN
  IF caller_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.users
    WHERE user_id = caller_id
      AND user_role IN ('super_admin', 'admin')
  ) THEN
    RAISE EXCEPTION 'admin privileges required' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'row_count',
    (SELECT count(*) FROM public.mv_hot_posts)
  );
END
$$;

REVOKE ALL ON FUNCTION public.admin_hot_feed_health() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_hot_feed_health()
  TO authenticated, service_role;
