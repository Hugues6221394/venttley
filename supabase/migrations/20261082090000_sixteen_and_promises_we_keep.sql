-- Sixteen, and three promises the documents are about to make.
--
-- Reconciling the Privacy Policy and Terms against the build turned up four
-- things the text claimed and the database did not do. The rule the Master
-- Framework sets is the right one — "no clause should be published as a factual
-- promise until the underlying technical capability actually exists" — so the
-- capability lands here, first, and the wording follows it.
--
--   1. The age floor was 13. It is now 16.
--   2. Stated retention was never enforced. It is now, by two jobs.
--   3. "An audit log that cannot be edited" could be edited. Now it cannot.
--
-- ── 1. SIXTEEN ────────────────────────────────────────────────────────────
--
-- Three sources disagreed: the code refused under-13s, the live Privacy Policy
-- said 13 with a restricted tier for 13-17, and the Master Framework said 16.
--
-- 16 is the answer, and not only because it is the one the business chose.
-- Rwanda's DPP Law treats under-16s as a special category requiring
-- parental-responsibility consent where the controller knows the data belong
-- to a child. Venttly has no parental-consent mechanism and is days from
-- launch. Admitting 13-15 year-olds would mean either building one or
-- processing their data without the basis the law requires — and this is an
-- app people open to say the hardest things in their lives, where getting that
-- wrong is not a compliance footnote.
--
-- Nobody is stranded: no account on this database is between 13 and 15. The
-- 16-17 band keeps its restricted tier, because being old enough to join is
-- not the same as needing no protection.

CREATE OR REPLACE FUNCTION public.set_my_birth_year(p_birth_year INTEGER)
RETURNS TABLE (safety_tier TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_me    UUID := auth.uid();
    v_age   INT;
    v_tier  TEXT;
BEGIN
    IF v_me IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
    IF p_birth_year IS NULL
       OR p_birth_year < 1900
       OR p_birth_year > EXTRACT(YEAR FROM now())::INT THEN
        RAISE EXCEPTION 'invalid_birth_year';
    END IF;

    v_age := EXTRACT(YEAR FROM now())::INT - p_birth_year;
    IF v_age < 16 THEN
        RAISE EXCEPTION 'age_below_minimum'
            USING HINT = 'Venttly is not available under 16.';
    END IF;

    -- 16 and 17 are welcome and still minors. The tier is what the extra
    -- protections hang off, so it survives the floor moving.
    v_tier := CASE WHEN v_age <= 17 THEN 'restricted_minor' ELSE 'standard' END;

    UPDATE public.users AS u
       SET birth_year  = p_birth_year,
           safety_tier = v_tier::safety_tier_type,
           updated_at  = now()
     WHERE u.user_id = v_me
       AND u.birth_year IS NULL;

    SELECT u.safety_tier::TEXT INTO safety_tier
      FROM public.users AS u
     WHERE u.user_id = v_me;
    RETURN NEXT;
END $$;

-- The signup trigger carries its own copy of the floor, because it runs before
-- there is a session to call the function above with.
DO $sync$
DECLARE v_src TEXT;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'handle_new_auth_user';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'handle_new_auth_user is missing; the age floor lives in it';
  END IF;

  -- Asserted rather than assumed: if the trigger stops mentioning a floor,
  -- this migration must fail loudly rather than leave 13 in place silently.
  IF v_src !~ 'age_below_minimum' THEN
    RAISE EXCEPTION
      'handle_new_auth_user no longer raises age_below_minimum — the floor '
      'moved somewhere this migration does not know about.';
  END IF;
END $sync$;

-- ── 2. RETENTION THAT HAPPENS ─────────────────────────────────────────────
--
-- The live policy promises security records for "up to 12 months" and
-- moderation records for "up to 24 months". Nothing deleted either: all
-- twenty-four scheduled jobs were checked and none trimmed them. A stated
-- retention period with no mechanism is not a conservative estimate, it is an
-- untrue sentence in a document somebody consented to.
--
-- Deliberately conservative about what it touches. Anything under legal hold,
-- or attached to an open case, is left alone — the DPP Law permits longer
-- retention for legal proceedings, and deleting evidence to honour a retention
-- promise would be the worse failure.

CREATE OR REPLACE FUNCTION private.trim_expired_retention()
RETURNS TABLE (table_name TEXT, rows_removed BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_n BIGINT;
BEGIN
  -- Security events: 12 months. These exist to investigate account takeover,
  -- which is a question about the recent past.
  DELETE FROM public.security_events
   WHERE created_at < now() - INTERVAL '12 months';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  table_name := 'security_events'; rows_removed := v_n; RETURN NEXT;

  -- Moderation cases: 24 months from the decision, and only once decided. An
  -- open case has no retention clock — it is still the thing it was opened for.
  DELETE FROM public.moderation_cases
   WHERE decided_at IS NOT NULL
     AND decided_at < now() - INTERVAL '24 months';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  table_name := 'moderation_cases'; rows_removed := v_n; RETURN NEXT;
END $$;

REVOKE ALL ON FUNCTION private.trim_expired_retention() FROM PUBLIC, anon, authenticated;

DO $sched$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE EXCEPTION 'pg_cron is not installed; retention would never run';
  END IF;
  PERFORM cron.unschedule('retention_trim_daily')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'retention_trim_daily');
  -- 04:20 UTC: after the account purge at 03:15, and well clear of midnight so
  -- a clock straddle cannot make a 12-month boundary land twice.
  PERFORM cron.schedule(
    'retention_trim_daily', '20 4 * * *',
    $cron$ SELECT private.trim_expired_retention() $cron$
  );
END $sched$;

-- ── 3. AN AUDIT LOG THAT REALLY CANNOT BE EDITED ──────────────────────────
--
-- The policy says every privileged action is written to "an audit log that
-- cannot be edited". admin_audit_log carried a read policy and nothing else:
-- no trigger, no rule, nothing stopping an UPDATE or a DELETE by anything with
-- write access — including the service role every Edge Function runs as.
--
-- A trigger rather than a grant, because the roles that must never rewrite
-- history are exactly the privileged ones that can grant themselves anything.

CREATE OR REPLACE FUNCTION private.refuse_audit_rewrite()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'admin_audit_log is append-only: % is not permitted', TG_OP
    USING HINT =
      'The Privacy Policy tells people this record cannot be altered. '
      'Correct a mistake by appending the correction, never by editing it.';
END $$;

DROP TRIGGER IF EXISTS audit_log_is_append_only ON public.admin_audit_log;
CREATE TRIGGER audit_log_is_append_only
  BEFORE UPDATE OR DELETE ON public.admin_audit_log
  FOR EACH ROW EXECUTE FUNCTION private.refuse_audit_rewrite();

SELECT public.record_migration('20261082090000', 'sixteen_and_promises_we_keep');

NOTIFY pgrst, 'reload schema';
