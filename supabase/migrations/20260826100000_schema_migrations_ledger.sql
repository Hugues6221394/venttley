-- A ledger of which migrations this database has actually run.
--
-- Every defect this week came from the same blind spot: migrations are applied
-- by hand, nothing records what landed, and a half-applied database looks
-- exactly like a working one. A missing column returns no key, which is
-- indistinguishable from a null, so the app renders letter avatars, groups with
-- no picture, music that does nothing — and reports none of it. We found each
-- one only because a person noticed the symptom.
--
-- db.missing_columns closed the *detection* half: when a read path is short a
-- column, it now says so. This closes the *prevention* half. The app can ask
-- the database which migrations it has and compare that to what the build
-- expects, before anybody notices a symptom.
--
-- Deliberately not a checksum ledger. Supabase's own CLI keeps one; this has to
-- survive files being applied out of order and by hand in the SQL editor, so it
-- records the plainest useful fact — this version ran, at this time — and
-- nothing that a manual apply could make wrong.

CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version    TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.schema_migrations IS
  'One row per migration that has run. Written by the migration itself; read by the app to detect a database that is behind the build.';

ALTER TABLE public.schema_migrations ENABLE ROW LEVEL SECURITY;

-- Signed-in only. Migration names are not secret, but they describe the shape
-- of the schema and there is no reason to hand that to an anonymous caller.
REVOKE ALL ON public.schema_migrations FROM PUBLIC, anon;
GRANT SELECT ON public.schema_migrations TO authenticated;

DROP POLICY IF EXISTS schema_migrations_read ON public.schema_migrations;
CREATE POLICY schema_migrations_read
  ON public.schema_migrations
  FOR SELECT
  TO authenticated
  USING (TRUE);

-- Nobody writes through the API. Rows come from migrations, which run as the
-- owner and bypass these grants.
REVOKE INSERT, UPDATE, DELETE ON public.schema_migrations
  FROM PUBLIC, anon, authenticated;

-- One line for a migration to declare itself. Kept as a function so the call
-- site in every future migration is short enough that nobody is tempted to
-- leave it out.
CREATE OR REPLACE FUNCTION public.record_migration(
  p_version TEXT,
  p_name TEXT
) RETURNS VOID
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.schema_migrations (version, name)
  VALUES (p_version, p_name)
  ON CONFLICT (version) DO NOTHING;
$$;

REVOKE ALL ON FUNCTION public.record_migration(TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

-- The ledger starts here, honestly.
--
-- It records nothing about the 175 migrations that came before it, because this
-- database has had files applied by hand, out of order, and partially — so any
-- backfill would be a guess written down as a fact, which is worse than an
-- empty table. The app only reports a version as missing when the version is
-- newer than the ledger's own, so history stays the job of db.missing_columns
-- and everything from here forward is knowable.
SELECT public.record_migration(
  '20260826100000', 'schema_migrations_ledger'
);

NOTIFY pgrst, 'reload schema';
