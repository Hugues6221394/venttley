-- Somewhere for users to report a bug or ask for a feature, and somewhere for
-- staff to read it.
--
-- There has been no in-app route for either. A person who finds a bug can
-- write a support case — which is a moderation surface, read by moderators,
-- and routes to nothing that fixes software — or say nothing. Most say
-- nothing, so the reports that matter most, from the people who hit them
-- first, never arrive at all.

CREATE TABLE IF NOT EXISTS public.feedback_reports (
  report_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- SET NULL, not CASCADE. A bug report outlives the account that sent it:
  -- the bug is still there, and deleting somebody's account should not delete
  -- the engineering record of what they found. What goes is the link to them.
  reporter_id  UUID REFERENCES public.users(user_id) ON DELETE SET NULL,

  kind         TEXT NOT NULL CHECK (kind IN ('bug', 'suggestion')),
  title        TEXT NOT NULL CHECK (length(btrim(title)) BETWEEN 3 AND 120),
  detail       TEXT NOT NULL CHECK (length(btrim(detail)) BETWEEN 10 AND 4000),

  -- Where they were and what they were running. A bug report without this is
  -- a bug report you cannot reproduce.
  screen       TEXT CHECK (screen IS NULL OR length(screen) <= 120),
  app_version  TEXT CHECK (app_version IS NULL OR length(app_version) <= 40),
  platform     TEXT CHECK (platform IS NULL OR length(platform) <= 40),
  device       TEXT CHECK (device IS NULL OR length(device) <= 120),

  status       TEXT NOT NULL DEFAULT 'new'
               CHECK (status IN ('new','triaged','planned','fixed','declined')),
  staff_note   TEXT CHECK (staff_note IS NULL OR length(staff_note) <= 2000),
  reviewed_by  UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
  reviewed_at  TIMESTAMPTZ,

  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_feedback_reports_queue
  ON public.feedback_reports (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_feedback_reports_reporter
  ON public.feedback_reports (reporter_id, created_at DESC);

ALTER TABLE public.feedback_reports ENABLE ROW LEVEL SECURITY;

-- A reporter can read their own, so the app can show them what happened to
-- it. Nobody writes through the table: submitting goes through an RPC that
-- rate limits and stamps the reporter, and triage goes through another that
-- checks staff.
DROP POLICY IF EXISTS "feedback own read" ON public.feedback_reports;
CREATE POLICY "feedback own read"
  ON public.feedback_reports FOR SELECT TO authenticated
  USING (reporter_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "feedback staff read" ON public.feedback_reports;
CREATE POLICY "feedback staff read"
  ON public.feedback_reports FOR SELECT TO authenticated
  USING (public.is_staff((SELECT auth.uid()),
                         ARRAY['super_admin','admin','moderator','support','analyst']));

REVOKE ALL ON public.feedback_reports FROM PUBLIC, anon;
GRANT SELECT ON public.feedback_reports TO authenticated;

-- ---------------------------------------------------------------------------
-- Submitting
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.submit_feedback(
  p_kind        TEXT,
  p_title       TEXT,
  p_detail      TEXT,
  p_screen      TEXT DEFAULT NULL,
  p_app_version TEXT DEFAULT NULL,
  p_platform    TEXT DEFAULT NULL,
  p_device      TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me UUID := (SELECT auth.uid());
  v_id UUID;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not_signed_in' USING ERRCODE = '42501';
  END IF;

  IF p_kind IS NULL OR p_kind NOT IN ('bug','suggestion') THEN
    RAISE EXCEPTION 'invalid_kind' USING ERRCODE = '22023';
  END IF;

  -- Ten an hour. Enough for somebody having a bad afternoon with the app,
  -- few enough that the queue cannot be flooded from one account.
  IF NOT public.claim_rate_limit('feedback_submit', 3600, 10) THEN
    RAISE EXCEPTION 'rate_limited' USING ERRCODE = '42901';
  END IF;

  INSERT INTO public.feedback_reports (
    reporter_id, kind, title, detail, screen, app_version, platform, device
  ) VALUES (
    v_me, p_kind, btrim(p_title), btrim(p_detail),
    NULLIF(btrim(COALESCE(p_screen, '')), ''),
    NULLIF(btrim(COALESCE(p_app_version, '')), ''),
    NULLIF(btrim(COALESCE(p_platform, '')), ''),
    NULLIF(btrim(COALESCE(p_device, '')), '')
  ) RETURNING report_id INTO v_id;

  RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION public.submit_feedback(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_feedback(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Reading: the reporter's own, and the staff queue
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.my_feedback(p_limit INTEGER DEFAULT 30)
RETURNS TABLE (
  report_id UUID, kind TEXT, title TEXT, detail TEXT,
  status TEXT, staff_note TEXT, created_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT f.report_id, f.kind, f.title, f.detail, f.status, f.staff_note,
         f.created_at
    FROM public.feedback_reports f
   WHERE f.reporter_id = (SELECT auth.uid())
   ORDER BY f.created_at DESC
   LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 30), 100));
$$;

REVOKE ALL ON FUNCTION public.my_feedback(INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_feedback(INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_feedback_queue(
  p_status TEXT DEFAULT NULL,
  p_kind   TEXT DEFAULT NULL,
  p_limit  INTEGER DEFAULT 50
) RETURNS TABLE (
  report_id UUID, kind TEXT, title TEXT, detail TEXT, screen TEXT,
  app_version TEXT, platform TEXT, device TEXT, status TEXT,
  staff_note TEXT, reporter_pseudonym TEXT, reviewed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_staff((SELECT auth.uid()),
        ARRAY['super_admin','admin','moderator','support','analyst']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT f.report_id, f.kind, f.title, f.detail, f.screen,
           f.app_version, f.platform, f.device, f.status, f.staff_note,
           -- The handle, not the id. A reviewer needs to recognise a repeat
           -- reporter; nothing here needs to identify the person further.
           --
           -- Cast: anonymous_pseudonym is varchar and the signature says TEXT,
           -- which RETURNS TABLE checks strictly enough to fail the call with
           -- "structure of query does not match function result type".
           u.anonymous_pseudonym::TEXT, f.reviewed_at, f.created_at
      FROM public.feedback_reports f
      LEFT JOIN public.users u ON u.user_id = f.reporter_id
     WHERE (p_status IS NULL OR f.status = p_status)
       AND (p_kind   IS NULL OR f.kind   = p_kind)
     ORDER BY
       -- New first, then oldest first inside a status: a report that has been
       -- waiting three weeks should not sink under this morning's.
       CASE WHEN f.status = 'new' THEN 0 ELSE 1 END,
       f.created_at ASC
     LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
END $$;

REVOKE ALL ON FUNCTION public.admin_feedback_queue(TEXT,TEXT,INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_feedback_queue(TEXT,TEXT,INTEGER)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Triage
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_triage_feedback(
  p_report UUID,
  p_status TEXT,
  p_note   TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_me UUID := (SELECT auth.uid());
BEGIN
  IF NOT public.is_staff(v_me, ARRAY['super_admin','admin','support']) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;

  IF p_status IS NULL
     OR p_status NOT IN ('new','triaged','planned','fixed','declined') THEN
    RAISE EXCEPTION 'invalid_status' USING ERRCODE = '22023';
  END IF;

  UPDATE public.feedback_reports
     SET status      = p_status,
         staff_note  = NULLIF(btrim(COALESCE(p_note, '')), ''),
         reviewed_by = v_me,
         reviewed_at = now(),
         updated_at  = now()
   WHERE report_id = p_report;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'report_not_found' USING ERRCODE = 'P0002';
  END IF;

  PERFORM public.admin_log(
    'feedback.triage', 'feedback', p_report, NULL, NULL,
    jsonb_build_object('status', p_status), p_note, '{}'::jsonb
  );
END $$;

REVOKE ALL ON FUNCTION public.admin_triage_feedback(UUID,TEXT,TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_triage_feedback(UUID,TEXT,TEXT)
  TO authenticated;

SELECT public.record_migration(
  '20261041090000', 'user_feedback_reports'
);

NOTIFY pgrst, 'reload schema';
