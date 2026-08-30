-- Stop showing a Tribe Keeper who reported them.
--
-- Found by testing: user B reported a post authored by user A, then A read
-- public.reports and got B's user id back. A is the Keeper of the Tribe the
-- post sits in, so the "reports mod read" policy from 0012 let them read every
-- report on every post in that Tribe — including reports about their own posts,
-- and including the reporter's identity.
--
-- That is the one thing reporting must never do. The brief says it plainly:
-- the reported user must not see "John reported you." On an anonymous platform
-- where people report harassment, handing the reporter's identity to the person
-- they reported invites retaliation — and here the person receiving it can ban
-- them from the Tribe.
--
-- WHY A COLUMN GRANT AND NOT A POLICY
--
-- Row level security decides which rows you see, not which columns. The
-- moderation queue genuinely needs these rows: a Keeper cannot act on a report
-- they cannot read. What they do not need, ever, is who filed it. Postgres
-- grants privileges per column, so that is the precise tool.
--
-- Nothing in the app breaks. The moderation queue selects report_id, reason,
-- note, is_resolved, created_at and post_id by name; reporter_id is not among
-- them and never was. Writing it is unaffected — INSERT privileges are separate
-- from SELECT, so reporting still records who reported.
--
-- PLATFORM STAFF STILL NEED IT
--
-- Investigating coordinated false reporting is impossible without knowing who
-- filed what. Staff read it through a function below rather than the table, so
-- the identity has exactly one route, and that route checks the caller is
-- staff instead of trusting a role claim from a client.

BEGIN;

-- Everything except reporter_id stays readable to whoever the policies allow.
-- Stated column by column because a bare GRANT SELECT would re-grant the whole
-- row and silently undo this the next time it ran.
REVOKE SELECT ON public.reports FROM authenticated;

DO $$
DECLARE
  v_cols TEXT;
BEGIN
  SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
    INTO v_cols
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name = 'reports'
     AND column_name <> 'reporter_id';

  IF v_cols IS NULL THEN
    RAISE EXCEPTION 'public.reports not found';
  END IF;

  EXECUTE format('GRANT SELECT (%s) ON public.reports TO authenticated', v_cols);
END $$;

COMMENT ON COLUMN public.reports.reporter_id IS
  'Who filed the report. Deliberately not readable by authenticated clients: a Keeper must never learn who reported them. Staff read it via public.report_reporter_for_staff.';

-- The one route to a reporter's identity.
CREATE OR REPLACE FUNCTION public.report_reporter_for_staff(p_report_id UUID)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_reporter UUID;
BEGIN
  IF NOT public.is_staff(
       (SELECT auth.uid()),
       ARRAY['super_admin', 'admin', 'moderator']
     ) THEN
    -- Not "no such report": a Keeper probing this should learn nothing about
    -- whether the report exists.
    RAISE EXCEPTION 'not_authorised';
  END IF;

  SELECT r.reporter_id INTO v_reporter
    FROM public.reports r WHERE r.report_id = p_report_id;

  RETURN v_reporter;
END $$;

REVOKE ALL ON FUNCTION public.report_reporter_for_staff(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_reporter_for_staff(UUID) TO authenticated;

COMMIT;

SELECT public.record_migration(
  '20260906090000', 'reporter_identity_privacy'
);

NOTIFY pgrst, 'reload schema';
