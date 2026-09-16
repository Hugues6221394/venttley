BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(17);

SET session_replication_role = replica;
INSERT INTO public.users (
  user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
  display_name, display_name_normalized, username_normalized,
  user_role, account_status, birth_year
) VALUES
  ('1a420000-0000-4000-8000-000000000001','reportadmin','reportadmin','x',
   'Report Admin','report admin','reportadmin','super_admin','active',1990),
  ('1a420000-0000-4000-8000-000000000002','reportmember','reportmember','x',
   'Report Member','report member','reportmember','normal','active',1995);
SET session_replication_role = origin;

INSERT INTO private.impact_report_snapshots (
  report_id,report_kind,title,audience,window_start,window_end,generated_by,checksum
) VALUES (
  '1a420000-0000-4000-8000-000000000010','monthly_impact','Older immutable snapshot','internal',
  '2024-01-01','2024-01-31','1a420000-0000-4000-8000-000000000001',repeat('a',64)
);

SELECT has_function('public','admin_impact_report',ARRAY['uuid'],'direct immutable report lookup exists');
SELECT has_function('private','refresh_impact_lookback',ARRAY['integer'],'bounded impact lookback job exists');
SELECT ok(
  NOT has_function_privilege('anon','public.admin_impact_report(uuid)','EXECUTE'),
  'anonymous callers cannot resolve reports'
);
SELECT ok(
  NOT has_function_privilege('authenticated','private.refresh_impact_lookback(integer)','EXECUTE')
  AND has_function_privilege('service_role','private.refresh_impact_lookback(integer)','EXECUTE'),
  'only the trusted service role can invoke the lookback batch'
);

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"1a420000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2"}',true);
SELECT throws_like(
  $q$SELECT * FROM public.admin_impact_report('1a420000-0000-4000-8000-000000000010')$q$,
  '%not_authorized%','ordinary members cannot resolve immutable reports');
RESET role;

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"1a420000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT is(
  (SELECT title FROM public.admin_impact_report('1a420000-0000-4000-8000-000000000010')),
  'Older immutable snapshot','authorized staff can resolve an exact report independently of list pagination');
RESET role;

SELECT is(
  (SELECT title FROM private.impact_metric_definitions WHERE metric_key='reach.active_users'),
  'Active person-days','daily active values are not mislabeled as cross-window unique people');
SELECT is(
  (SELECT title FROM private.impact_metric_definitions WHERE metric_key='community.support_participants'),
  'Support participant-days','daily support participation is labeled as additive person-days');
SELECT ok(
  (SELECT command LIKE '%refresh_impact_lookback(30)%' FROM cron.job WHERE jobname='venttly-impact-daily-v1'),
  'the daily schedule recomputes delayed outcomes');

SELECT has_index('public','users','users_impact_created_idx','account cohorts have a time-first batch index');
SELECT has_index('public','posts','posts_impact_created_idx','Vent activity has a time-first batch index');
SELECT has_index('public','posts_comments','posts_comments_impact_created_idx','comment activity has a time-first batch index');
SELECT has_index('public','post_likes','post_likes_impact_created_idx','reaction activity has a time-first batch index');
SELECT has_index('public','tribe_messages','tribe_messages_impact_created_idx','tribe activity has a time-first batch index');
SELECT has_index('public','chat_messages','chat_messages_impact_created_idx','chat activity has a time-first batch index');
SELECT has_index('public','reports','reports_impact_created_idx','report volume has a time-first batch index');
SELECT has_index('public','moderation_cases','moderation_cases_impact_opened_idx','moderation cohorts have a time-first batch index');

SELECT * FROM finish();
ROLLBACK;
