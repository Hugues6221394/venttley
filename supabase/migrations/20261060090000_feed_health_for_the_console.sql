-- What the feed is actually doing, for the people who have to answer for it.
--
-- A ranking change is easy to ship and hard to notice going wrong. The
-- failures are quiet ones: the same twenty posts every morning, nine tenths
-- of what gets written never shown to anybody, one prolific account taking
-- the whole country's first page. None of that raises an error.
--
-- These are the numbers that would show it, in one role-checked call.

CREATE INDEX IF NOT EXISTS post_impressions_seen_idx
  ON public.post_impressions (seen_at DESC);

CREATE OR REPLACE FUNCTION public.admin_feed_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  caller_id UUID := (SELECT auth.uid());
  v_since   TIMESTAMPTZ := now() - INTERVAL '24 hours';
  v_week    TIMESTAMPTZ := now() - INTERVAL '7 days';
  v_shown   BIGINT;
  v_readers BIGINT;
  v_repeats BIGINT;
  v_written BIGINT;
  v_reached BIGINT;
  v_loudest JSONB;
BEGIN
  IF caller_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.users
     WHERE user_id = caller_id
       AND user_role IN ('super_admin', 'admin', 'analyst', 'read_only_auditor')
  ) THEN
    RAISE EXCEPTION 'admin privileges required' USING ERRCODE = '42501';
  END IF;

  SELECT count(*), count(DISTINCT user_id),
         count(*) FILTER (WHERE seen_count > 1)
    INTO v_shown, v_readers, v_repeats
    FROM public.post_impressions
   WHERE seen_at > v_since;

  -- Coverage. The number that says whether writing here is worth it: of
  -- everything posted this week, how much has been put in front of anybody
  -- at all.
  SELECT count(*),
         count(*) FILTER (
           WHERE EXISTS (
             SELECT 1 FROM public.post_impressions i WHERE i.post_id = p.post_id
           )
         )
    INTO v_written, v_reached
    FROM public.posts p
   WHERE p.created_at > v_week
     AND p.deleted_at IS NULL
     AND p.is_story = FALSE;

  -- Concentration: the five accounts holding the most of everybody's feed.
  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::JSONB) INTO v_loudest
    FROM (
      SELECT u.anonymous_pseudonym AS author,
             count(*) AS impressions,
             round(
               100.0 * count(*) / GREATEST(v_shown, 1), 2
             )::FLOAT AS share_pct
        FROM public.post_impressions i
        JOIN public.posts p ON p.post_id = i.post_id
        JOIN public.users u ON u.user_id = p.author_id
       WHERE i.seen_at > v_since
       GROUP BY u.anonymous_pseudonym
       ORDER BY count(*) DESC
       LIMIT 5
    ) t;

  RETURN jsonb_build_object(
    'window_hours', 24,
    'posts_shown', v_shown,
    'readers', v_readers,
    -- How much of what people saw, they had already seen. This is the number
    -- that goes up when the feed starts repeating itself.
    'repeat_share_pct',
      round(100.0 * v_repeats / GREATEST(v_shown, 1), 2)::FLOAT,
    'posts_per_reader',
      round(v_shown::NUMERIC / GREATEST(v_readers, 1), 1)::FLOAT,
    'posts_written_7d', v_written,
    'posts_reaching_someone_7d', v_reached,
    'coverage_pct',
      round(100.0 * v_reached / GREATEST(v_written, 1), 2)::FLOAT,
    'not_interested_24h', (
      SELECT COALESCE(jsonb_object_agg(reason, n), '{}'::JSONB)
        FROM (
          SELECT reason, count(*) AS n
            FROM public.post_not_interested
           WHERE created_at > v_since
           GROUP BY reason
        ) r
    ),
    'loudest_authors', v_loudest,
    'cached_rankings', (SELECT count(*) FROM public.feed_sessions),
    'generated_at', now()
  );
END $$;

REVOKE ALL ON FUNCTION public.admin_feed_health() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_feed_health() TO authenticated, service_role;

SELECT public.record_migration(
  '20261060090000', 'feed_health_for_the_console'
);

NOTIFY pgrst, 'reload schema';
