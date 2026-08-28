BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(6);

SELECT ok(
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'public.search_global(text,integer)'::REGPROCEDURE
    ),
    'pg_catalog.greatest('
  ) = 0,
  'global search does not schema-qualify the GREATEST expression'
);

SELECT ok(
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'public.search_global(text,integer)'::REGPROCEDURE
    ),
    'pg_catalog.least('
  ) = 0,
  'global search does not schema-qualify the LEAST expression'
);

SELECT ok(
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'public.search_music(text,text,integer,integer)'::REGPROCEDURE
    ),
    'pg_catalog.greatest('
  ) = 0,
  'music search does not schema-qualify the GREATEST expression'
);

SELECT ok(
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'public.search_music(text,text,integer,integer)'::REGPROCEDURE
    ),
    'pg_catalog.least('
  ) = 0,
  'music search does not schema-qualify the LEAST expression'
);

SELECT ok(
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'public.search_tag_candidates(text,integer)'::REGPROCEDURE
    ),
    'pg_catalog.greatest('
  ) = 0,
  'mention search does not schema-qualify the GREATEST expression'
);

SELECT ok(
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'public.search_tag_candidates(text,integer)'::REGPROCEDURE
    ),
    'pg_catalog.least('
  ) = 0,
  'mention search does not schema-qualify the LEAST expression'
);

SELECT * FROM finish();

ROLLBACK;
