-- Backfill the ledger for five migrations that never recorded themselves.
--
-- 20261026 through 20261029090001 were written without the closing
-- record_migration() call, so a database that has run them cannot say so. The
-- files now end with it, which fixes every database created from here on and
-- fixes none that already exist: `supabase db push` tracks applied files by
-- name, so appending a statement to an applied migration never runs it.
--
-- Hence this. It is deliberately not a list of INSERTs.
--
-- Four of these five are believed to be applied to production and the fifth is
-- believed not to be, and "believed" is not good enough to write into a table
-- whose entire purpose is to be trusted. So each one is checked before it is
-- claimed: every migration here creates something distinctive, and the ledger
-- row is written only if that object is present. On a database that ran four
-- of them this records four; on a fresh one that ran all five through the
-- files themselves, record_migration is ON CONFLICT DO NOTHING and this is a
-- no-op. Either way the ledger ends up describing the database it is in rather
-- than the database somebody assumed.

DO $$
DECLARE
  -- A VALUES list and a record loop, not a two-dimensional array.
  --
  -- The first version of this built ARRAY[ARRAY[...], ...] and walked it with
  -- v_rows[i:i][1:4]. Slicing a 2-D array yields a 2-D array, so every field
  -- read came back NULL, and the whole block ran to completion recording
  -- nothing and raising no error — a backfill that silently did not backfill.
  -- Caught by running it against a database rather than by reading it.
  r        RECORD;
  v_exists BOOLEAN;
  v_done   TEXT[] := ARRAY[]::TEXT[];
  v_absent TEXT[] := ARRAY[]::TEXT[];
BEGIN
  FOR r IN
    SELECT *
      FROM (VALUES
        ('20261026090000', 'impact_evidence_platform_phase1',
         'table',    'private.analytics_subjects'),
        ('20261027090000', 'admin_control_plane_observability',
         'function', 'public.admin_control_plane_snapshot'),
        ('20261028090000', 'impact_reporting_runtime_hardening',
         'function', 'public.admin_impact_report'),
        ('20261029090000', 'operational_governance_workflows',
         'table',    'private.admin_operation_receipts'),
        ('20261029090001', 'staff_inbox_foundation',
         'table',    'private.staff_inbox_control')
      ) AS t(version, name, kind, object)
  LOOP
    IF r.kind = 'table' THEN
      v_exists := to_regclass(r.object) IS NOT NULL;
    ELSE
      v_exists := EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname || '.' || p.proname = r.object
      );
    END IF;

    IF v_exists THEN
      PERFORM public.record_migration(r.version, r.name);
      v_done := v_done || r.name;
    ELSE
      v_absent := v_absent || r.name;
    END IF;
  END LOOP;

  IF array_length(v_done, 1) IS NULL AND array_length(v_absent, 1) IS NULL THEN
    RAISE EXCEPTION
      'schema ledger backfill checked nothing — the loop did not run';
  END IF;

  RAISE NOTICE 'schema ledger backfill: recorded [%], not applied here [%]',
    COALESCE(array_to_string(v_done, ', '), ''),
    COALESCE(array_to_string(v_absent, ', '), '');
END
$$;

SELECT public.record_migration(
  '20261037090000', 'backfill_schema_ledger'
);

NOTIFY pgrst, 'reload schema';
