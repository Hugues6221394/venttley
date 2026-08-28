-- PostgreSQL implements GREATEST/LEAST as special conditional expressions,
-- not ordinary pg_catalog functions. A previous function-hardening pass
-- schema-qualified them while locking SECURITY DEFINER search paths, causing
-- global search, mention autocomplete, and music search to fail at runtime.
--
-- Repair the exact affected entry points in place. CREATE OR REPLACE keeps
-- their OIDs, owners, grants, volatility, and security contexts unchanged.
BEGIN;

DO $repair_search_bounds$
DECLARE
  target REGPROCEDURE;
  definition TEXT;
BEGIN
  FOREACH target IN ARRAY ARRAY[
    'public.search_global(text,integer)'::REGPROCEDURE,
    'public.search_music(text,text,integer,integer)'::REGPROCEDURE,
    'public.search_tag_candidates(text,integer)'::REGPROCEDURE
  ]
  LOOP
    SELECT pg_catalog.pg_get_functiondef(target)
      INTO definition;

    definition := pg_catalog.replace(
      pg_catalog.replace(
        definition,
        'pg_catalog.greatest(',
        'greatest('
      ),
      'pg_catalog.least(',
      'least('
    );

    EXECUTE definition;
  END LOOP;
END;
$repair_search_bounds$;

DO $verify_search_bounds$
DECLARE
  broken_count INTEGER;
BEGIN
  SELECT pg_catalog.count(*)::INTEGER
    INTO broken_count
    FROM pg_catalog.pg_proc AS procedure
   WHERE procedure.oid = ANY (ARRAY[
     'public.search_global(text,integer)'::REGPROCEDURE::OID,
     'public.search_music(text,text,integer,integer)'::REGPROCEDURE::OID,
     'public.search_tag_candidates(text,integer)'::REGPROCEDURE::OID
   ])
     AND (
       pg_catalog.pg_get_functiondef(procedure.oid)
         LIKE '%pg_catalog.greatest(%'
       OR pg_catalog.pg_get_functiondef(procedure.oid)
         LIKE '%pg_catalog.least(%'
     );

  IF broken_count <> 0 THEN
    RAISE EXCEPTION 'search bound qualification repair incomplete';
  END IF;
END;
$verify_search_bounds$;

COMMIT;
