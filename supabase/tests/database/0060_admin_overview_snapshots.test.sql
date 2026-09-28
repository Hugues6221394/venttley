BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
SELECT private.refresh_admin_overview('activity');
CREATE TEMP TABLE baseline AS SELECT payload FROM private.admin_overview_snapshots WHERE panel='activity';
SET session_replication_role=replica;
INSERT INTO public.users(user_id,anonymous_pseudonym,avatar_seed,recovery_key_hash,display_name,display_name_normalized,username_normalized,user_role,account_status,birth_year,created_at)
SELECT ('1a600000-0000-4000-8000-'||lpad(i::TEXT,12,'0'))::UUID,'overviewtest'||i,'x','x','Overview','overview','overviewtest'||i,
  (CASE WHEN i=1 THEN 'super_admin' ELSE 'normal' END)::public.user_role_type,'active',1990,now()-interval '60 days'
FROM generate_series(1,3) i;
INSERT INTO public.posts(post_id,author_id,content,category_name,post_mood,created_at,deleted_at)
VALUES ('1a600000-1000-4000-8000-000000000001','1a600000-0000-4000-8000-000000000002','synthetic test','mental_health','hopeful',now()-interval '1 hour',NULL),
('1a600000-1000-4000-8000-000000000002','1a600000-0000-4000-8000-000000000003','removed test','mental_health','hopeful',now()-interval '1 hour',now());
INSERT INTO public.posts_comments(comment_id,post_id,author_id,content,path,created_at)
VALUES ('1a600000-2000-4000-8000-000000000001','1a600000-1000-4000-8000-000000000001','1a600000-0000-4000-8000-000000000002','synthetic comment','test1',now()-interval '1 hour'),
('1a600000-2000-4000-8000-000000000002','1a600000-1000-4000-8000-000000000001','1a600000-0000-4000-8000-000000000003','synthetic comment','test2',now()-interval '1 hour');
SET session_replication_role=origin;
SELECT lives_ok($$SELECT private.refresh_admin_overview('activity')$$,'activity refresh works');
SELECT is((SELECT (payload->>'unique_writers')::BIGINT FROM private.admin_overview_snapshots WHERE panel='activity'),
  (SELECT (payload->>'unique_writers')::BIGINT+2 FROM baseline),'post and comment author counted once, comment-only author counted');
SELECT is((SELECT (payload->>'vents')::BIGINT FROM private.admin_overview_snapshots WHERE panel='activity'),
  (SELECT (payload->>'vents')::BIGINT+1 FROM baseline),'removed Vent excluded');
SELECT is((SELECT (payload->>'comments')::BIGINT FROM private.admin_overview_snapshots WHERE panel='activity'),
  (SELECT (payload->>'comments')::BIGINT+2 FROM baseline),'comment count remains separate from unique writers');
SELECT lives_ok($$SELECT private.refresh_admin_overview('activity')$$,'repeat refresh safe');
SELECT ok(NOT has_function_privilege('anon','public.admin_overview_panel(text)','EXECUTE'),'anonymous API denied');
SELECT ok(NOT has_function_privilege('authenticated','private.refresh_admin_overview(text)','EXECUTE'),'staff cannot trigger aggregation');
SELECT ok(NOT has_table_privilege('authenticated','private.admin_overview_snapshots','SELECT'),'snapshot storage is private');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid='private.admin_overview_snapshots'::regclass),'private snapshot RLS enabled');
SELECT is((SELECT count(*)::INTEGER FROM cron.job WHERE jobname LIKE 'admin-overview-%' AND active),0,'workers installed disabled');
SELECT private.refresh_admin_overview(panel) FROM unnest(ARRAY['queues','reports','regions']) panel;
SELECT is((SELECT count(*)::INTEGER FROM private.admin_overview_snapshots WHERE error_code IS NOT NULL),0,'all panel refreshes succeed');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"1a600000-0000-4000-8000-000000000002","role":"authenticated"}',true);
SELECT throws_like($$SELECT public.admin_overview_panel('activity')$$,'%not_authorized%','member cannot read staff metrics');
SELECT set_config('request.jwt.claims','{"sub":"1a600000-0000-4000-8000-000000000001","role":"authenticated"}',true);
SELECT is(public.admin_overview_panel('activity')->>'state','ready','active super admin reads ready snapshot');
SELECT throws_like($$SELECT public.admin_overview_panel('unknown')$$,'%invalid_panel%','arbitrary panel rejected');
SELECT ok((public.admin_overview_panel('queues')->'data') ? 'support','super admin sees support aggregate');
RESET ROLE;
-- Changes are test-only; suppress unrelated profile triggers/FKs.
SET session_replication_role=replica;
UPDATE public.users SET user_role='support' WHERE user_id='1a600000-0000-4000-8000-000000000001';
SET session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT ok(NOT ((public.admin_overview_panel('queues')->'data') ? 'moderation'),'support cannot read moderation queue count');
SELECT ok((public.admin_overview_panel('queues')->'data') ? 'support','support retains its queue');
RESET ROLE;
SET session_replication_role=replica;
UPDATE public.users SET user_role='analyst' WHERE user_id='1a600000-0000-4000-8000-000000000001';
SET session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT is(public.admin_overview_panel('queues')->'data','{}'::JSONB,'analyst has no triage counts');
SELECT is(public.admin_overview_panel('activity')->>'state','ready','analyst may read aggregate activity');
RESET ROLE;
UPDATE private.admin_overview_snapshots SET measured_at=now()-interval '11 minutes' WHERE panel='activity';
SET LOCAL ROLE authenticated;
SELECT is(public.admin_overview_panel('activity')->>'state','stale','old snapshot explicitly stale');
RESET ROLE;
UPDATE private.admin_overview_snapshots SET measured_at=now(),error_code='XX000' WHERE panel='activity';
SET LOCAL ROLE authenticated;
SELECT is(public.admin_overview_panel('activity')->>'state','stale','failed refresh cannot report healthy');
RESET ROLE;
UPDATE private.admin_overview_snapshots SET payload=NULL WHERE panel='activity';
SET LOCAL ROLE authenticated;
SELECT is(public.admin_overview_panel('activity')->>'state','unavailable','missing data is not zero');
SELECT is(public.admin_overview_panel('reports')->>'state','ready','one failed panel does not fail others');
RESET ROLE;
SET session_replication_role=replica;
UPDATE public.users SET account_status='suspended' WHERE user_id='1a600000-0000-4000-8000-000000000001';
SET session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT throws_like($$SELECT public.admin_overview_panel('reports')$$,'%not_authorized%','suspended staff loses snapshot access with same JWT');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
