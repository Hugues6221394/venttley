BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(30);

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

SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.claim_rate_limit(text,integer,integer)', 'EXECUTE'
  ),
  'anonymous callers cannot manipulate rate-limit state'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.claim_rate_limit(text,integer,integer)', 'EXECUTE'
  ),
  'signed-in callers cannot reset their rate-limit windows'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.claim_rate_limit(text,integer,integer)', 'EXECUTE'
  ),
  'trusted server paths retain access to the rate-limit primitive'
);

SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.bump_moderation_hit(text)', 'EXECUTE'
  ),
  'anonymous callers cannot forge moderation cache metrics'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.bump_moderation_hit(text)', 'EXECUTE'
  ),
  'signed-in callers cannot forge moderation cache metrics'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.bump_moderation_hit(text)', 'EXECUTE'
  ),
  'the moderation worker can record cache hits'
);

SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.pick_spaces_for_summary(integer)', 'EXECUTE'
  ),
  'anonymous callers cannot enumerate summary work'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.pick_spaces_for_summary(integer)', 'EXECUTE'
  ),
  'signed-in callers cannot enumerate summary work'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.pick_spaces_for_summary(integer)', 'EXECUTE'
  ),
  'the summary worker can enumerate bounded work'
);

SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.publish_scheduled_prompts()', 'EXECUTE'
  ),
  'anonymous callers cannot publish scheduled prompts'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.publish_scheduled_prompts()', 'EXECUTE'
  ),
  'signed-in callers cannot publish scheduled prompts'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.publish_scheduled_prompts()', 'EXECUTE'
  ),
  'the scheduled worker can publish prompts'
);

SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.purge_due_accounts()', 'EXECUTE'
  ),
  'anonymous callers cannot purge accounts'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.purge_due_accounts()', 'EXECUTE'
  ),
  'signed-in callers cannot purge accounts'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.purge_due_accounts()', 'EXECUTE'
  ),
  'the account-purge worker can purge due accounts'
);

SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.purge_due_tribes()', 'EXECUTE'
  ),
  'anonymous callers cannot purge Tribes'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.purge_due_tribes()', 'EXECUTE'
  ),
  'signed-in callers cannot purge Tribes'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.purge_due_tribes()', 'EXECUTE'
  ),
  'the Tribe-purge worker can purge due Tribes'
);

SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.purge_stale_moderation_verdicts()', 'EXECUTE'
  ),
  'anonymous callers cannot purge moderation cache state'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.purge_stale_moderation_verdicts()', 'EXECUTE'
  ),
  'signed-in callers cannot purge moderation cache state'
);
SELECT ok(
  has_function_privilege(
    'service_role', 'public.purge_stale_moderation_verdicts()', 'EXECUTE'
  ),
  'scheduled maintenance can purge stale moderation state'
);

SELECT * FROM finish();
ROLLBACK;
