-- CLI generated 20260924162434; ordered after the existing future-dated
-- governance dependency. Additive. Worker jobs are installed INACTIVE.
CREATE TABLE IF NOT EXISTS private.admin_overview_snapshots (
  panel TEXT PRIMARY KEY CHECK (panel IN ('activity','queues','reports','regions')),
  payload JSONB,
  measured_at TIMESTAMPTZ,
  attempted_at TIMESTAMPTZ,
  error_code TEXT
);
ALTER TABLE private.admin_overview_snapshots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.admin_overview_snapshots FROM PUBLIC,anon,authenticated;

-- Privileged internal aggregation only: never executable by an API caller.
-- One job per panel isolates failures and avoids per-operator exact counts.
CREATE OR REPLACE FUNCTION private.refresh_admin_overview(p_panel TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result JSONB; stamp TIMESTAMPTZ:=statement_timestamp();
BEGIN
  IF p_panel IS NULL OR p_panel NOT IN ('activity','queues','reports','regions') THEN RAISE EXCEPTION 'invalid_panel'; END IF;
  IF NOT pg_try_advisory_xact_lock(hashtextextended('admin_overview:'||p_panel,0)) THEN RETURN; END IF;
  BEGIN
    CASE p_panel
    WHEN 'activity' THEN
      WITH member_counts AS (
        SELECT count(*) AS total,
          count(*) FILTER (WHERE created_at>=stamp-interval '24 hours' AND created_at<stamp) AS recent,
          count(*) FILTER (WHERE created_at>=stamp-interval '48 hours' AND created_at<stamp-interval '24 hours') AS previous FROM public.users
      ), recent_posts AS MATERIALIZED (
        SELECT author_id,created_at FROM public.posts WHERE deleted_at IS NULL
          AND created_at>=stamp-interval '48 hours' AND created_at<stamp
      ), recent_comments AS MATERIALIZED (
        SELECT c.author_id FROM public.posts_comments c JOIN public.posts p ON p.post_id=c.post_id
        WHERE c.deleted_at IS NULL AND p.deleted_at IS NULL
          AND c.created_at>=stamp-interval '24 hours' AND c.created_at<stamp
      ), writers AS (
        SELECT author_id FROM recent_posts WHERE created_at>=stamp-interval '24 hours'
        UNION SELECT author_id FROM recent_comments
      ) SELECT jsonb_build_object('total_members',m.total,'new_members',m.recent,'previous_members',m.previous,
        'unique_writers',(SELECT count(*) FROM writers WHERE author_id IS NOT NULL),
        'vents',(SELECT count(*) FROM recent_posts WHERE created_at>=stamp-interval '24 hours'),
        'previous_vents',(SELECT count(*) FROM recent_posts WHERE created_at<stamp-interval '24 hours'),
        'comments',(SELECT count(*) FROM recent_comments)) INTO result FROM member_counts m;
    WHEN 'queues' THEN
      SELECT jsonb_build_object(
        'moderation',(SELECT count(*) FROM public.reports WHERE is_resolved=false),
        'appeals',(SELECT count(*) FROM public.moderation_appeals WHERE status='open'),
        'support',(SELECT count(*) FROM private.support_cases WHERE status NOT IN ('resolved','closed'))
      ) INTO result;
    WHEN 'reports' THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object('day',day,'count',n) ORDER BY day),'[]'::JSONB) INTO result
      FROM (SELECT (created_at AT TIME ZONE 'UTC')::date::TEXT AS day,count(*) AS n
        FROM public.reports WHERE created_at>=date_trunc('day',stamp AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'-interval '29 days'
          AND created_at<stamp GROUP BY 1) r;
    WHEN 'regions' THEN
      SELECT jsonb_build_object('total_members',(SELECT count(*) FROM public.users),
        'rows',COALESCE(jsonb_agg(jsonb_build_object('country',country,'count',n) ORDER BY n DESC,country),'[]'::JSONB)) INTO result
      FROM (SELECT upper(btrim(home_country)) AS country,count(*) AS n FROM public.users
        WHERE home_country ~* '^[A-Z]{2}$' GROUP BY 1 HAVING count(*)>=10
        ORDER BY n DESC,country LIMIT 8) r;
    END CASE;
    INSERT INTO private.admin_overview_snapshots(panel,payload,measured_at,attempted_at,error_code)
      VALUES(p_panel,result,stamp,stamp,NULL)
      ON CONFLICT(panel) DO UPDATE SET payload=EXCLUDED.payload,measured_at=EXCLUDED.measured_at,
        attempted_at=EXCLUDED.attempted_at,error_code=NULL;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO private.admin_overview_snapshots(panel,attempted_at,error_code) VALUES(p_panel,stamp,SQLSTATE)
      ON CONFLICT(panel) DO UPDATE SET attempted_at=EXCLUDED.attempted_at,error_code=EXCLUDED.error_code;
    -- No exception text or source content retained. Last-good snapshot remains
    -- distinguishable from current data through its timestamp and failed state.
  END;
END;
$$;
REVOKE ALL ON FUNCTION private.refresh_admin_overview(TEXT) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.admin_overview_panel(p_panel TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE row private.admin_overview_snapshots%ROWTYPE; result JSONB; actor UUID:=auth.uid();
BEGIN
  IF NOT public.is_staff(actor,ARRAY['super_admin','admin','moderator','support','analyst','read_only_auditor']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501'; END IF;
  IF NOT public.claim_rate_limit('staff_overview_read',60,120) THEN RAISE EXCEPTION 'rate_limited'; END IF;
  IF p_panel IS NULL OR p_panel NOT IN ('activity','queues','reports','regions') THEN RAISE EXCEPTION 'invalid_panel' USING ERRCODE='22023'; END IF;
  SELECT * INTO row FROM private.admin_overview_snapshots WHERE panel=p_panel;
  IF NOT FOUND OR row.payload IS NULL THEN RETURN jsonb_build_object('state','unavailable','measured_at',NULL,'data',NULL); END IF;
  result:=row.payload;
  IF p_panel='queues' THEN
    result:='{}'::JSONB;
    IF public.is_staff(actor,ARRAY['super_admin','admin','moderator']) THEN
      result:=result||jsonb_build_object('moderation',row.payload->'moderation','appeals',row.payload->'appeals'); END IF;
    IF public.is_staff(actor,ARRAY['super_admin','admin','support']) THEN result:=result||jsonb_build_object('support',row.payload->'support'); END IF;
  END IF;
  RETURN jsonb_build_object('state',CASE WHEN row.error_code IS NOT NULL OR row.measured_at<now()-interval '10 minutes'
      OR row.measured_at>now()+interval '1 minute' THEN 'stale' ELSE 'ready' END,
    'measured_at',row.measured_at,'data',result);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_overview_panel(TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_overview_panel(TEXT) TO authenticated;

-- Explicit rollout: activate only after reviewed staging warm-up and query plans.
-- Disabling these jobs preserves snapshots; they become visibly stale.
DO $$ DECLARE name TEXT; id BIGINT; BEGIN
  FOREACH name IN ARRAY ARRAY['activity','queues','reports','regions'] LOOP
    IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobname='admin-overview-'||name) THEN
      SELECT cron.schedule('admin-overview-'||name,'*/5 * * * *',
        format('SET statement_timeout = ''20s''; SELECT private.refresh_admin_overview(%L);',name)) INTO id;
      PERFORM cron.alter_job(id,active:=false);
    END IF;
  END LOOP;
END $$;
SELECT public.record_migration('20261029090003','admin_overview_snapshots');
NOTIFY pgrst,'reload schema';
