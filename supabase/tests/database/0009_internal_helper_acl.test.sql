BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(9);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public._notify(uuid,uuid,text,text,uuid,text,text,interval,jsonb)',
    'EXECUTE'
  ),
  'signed-in clients cannot forge notifications through _notify'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public._notify(uuid,uuid,text,text,uuid,text,text,interval,jsonb)',
    'EXECUTE'
  ),
  'anonymous clients cannot invoke _notify'
);
SELECT ok(
  has_function_privilege(
    'service_role',
    'public._notify(uuid,uuid,text,text,uuid,text,text,interval,jsonb)',
    'EXECUTE'
  ),
  'service role retains operational access to _notify'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public._notify_mentions(uuid,text,text,uuid,jsonb)',
    'EXECUTE'
  ),
  'signed-in clients cannot forge mention notifications'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public._notify_mentions(uuid,text,text,uuid,jsonb)',
    'EXECUTE'
  ),
  'anonymous clients cannot invoke _notify_mentions'
);
SELECT ok(
  has_function_privilege(
    'service_role',
    'public._notify_mentions(uuid,text,text,uuid,jsonb)',
    'EXECUTE'
  ),
  'service role retains operational access to _notify_mentions'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public._writer_state(uuid)', 'EXECUTE'
  ),
  'signed-in clients cannot probe arbitrary writer state'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public._writer_state(uuid)', 'EXECUTE'
  ),
  'anonymous clients cannot invoke _writer_state'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public._writer_state(uuid)', 'EXECUTE'
  ),
  'service role retains operational access to _writer_state'
);

SELECT * FROM finish();
ROLLBACK;
