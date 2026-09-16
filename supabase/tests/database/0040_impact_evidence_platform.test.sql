BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(29);

SET session_replication_role = replica;
INSERT INTO public.users (
  user_id, anonymous_pseudonym, avatar_seed, recovery_key_hash,
  display_name, display_name_normalized, username_normalized,
  user_role, account_status, birth_year
) VALUES
  ('1a400000-0000-4000-8000-000000000001','impactadmin','impactadmin','x',
   'Impact Admin','impact admin','impactadmin','super_admin','active',1990),
  ('1a400000-0000-4000-8000-000000000002','impactmember','impactmember','x',
   'Impact Member','impact member','impactmember','normal','active',1995);
SET session_replication_role = origin;

SELECT has_table('private','analytics_subjects','analytics identity mapping exists outside the exposed public schema');
SELECT has_table('private','impact_metric_definitions','the versioned KPI dictionary exists');
SELECT has_table('private','impact_daily_metrics','daily aggregates have a canonical fact table');
SELECT has_table('private','impact_report_snapshots','immutable report snapshots have a canonical table');
SELECT has_table('private','impact_consent_receipts','optional research consent has a separate append-only ledger');

SELECT ok(
  NOT has_table_privilege('authenticated','private.analytics_subjects','SELECT')
  AND NOT has_table_privilege('authenticated','private.impact_daily_metrics','SELECT')
  AND NOT has_table_privilege('authenticated','private.impact_report_snapshots','SELECT')
  AND NOT has_table_privilege('authenticated','private.impact_consent_receipts','SELECT'),
  'signed-in clients cannot read private identities, facts, reports, or consent ledgers'
);

SELECT ok(
  NOT has_function_privilege('anon','public.admin_impact_metrics(date,date,text,text,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.admin_impact_methodology()','EXECUTE')
  AND NOT has_function_privilege('anon','public.admin_impact_reports(integer)','EXECUTE')
  AND NOT has_function_privilege('anon','public.admin_generate_impact_report(text,text,text,date,date,text,text,text)','EXECUTE'),
  'no impact administration function is callable anonymously'
);

SELECT ok(
  NOT has_function_privilege('authenticated','private.refresh_impact_daily(date)','EXECUTE')
  AND NOT has_function_privilege('authenticated','private.run_impact_data_quality(date)','EXECUTE'),
  'members and staff cannot invoke trusted aggregate jobs directly'
);

SELECT is(
  private.sanitize_event_props('{"content":"private words","tribe_id":"1a400000-0000-4000-8000-000000000002","has_music":true}'::jsonb),
  '{"has_music": true}'::jsonb,
  'server sanitization removes authored content and resource identifiers'
);

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"1a400000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}',true);

SELECT lives_ok($q$SELECT public.my_analytics_subject()$q$,
  'an authenticated member can obtain only their own product-analytics subject');
SELECT isnt(public.my_analytics_subject(),
  '1a400000-0000-4000-8000-000000000002'::uuid,
  'the product-analytics subject is not the Auth user id');
SELECT is(public.my_analytics_subject(),public.my_analytics_subject(),
  'the product-analytics subject is stable and idempotent');

SELECT throws_like(
  $q$SELECT * FROM public.admin_impact_metrics('2024-01-01','2024-01-31','overall','all','none')$q$,
  '%not_authorized%','ordinary members cannot read aggregate impact metrics');
SELECT throws_like(
  $q$SELECT * FROM public.admin_impact_methodology()$q$,
  '%not_authorized%','ordinary members cannot read internal methodology metadata');
SELECT throws_like(
  $q$SELECT * FROM public.admin_impact_data_quality()$q$,
  '%not_authorized%','ordinary members cannot read internal data-quality operations');
SELECT throws_like(
  $q$SELECT public.admin_generate_impact_report('monthly_impact','Attack report','internal','2024-01-01','2024-01-31','none',NULL,NULL)$q$,
  '%not_authorized%','ordinary members cannot generate reports');
RESET role;

INSERT INTO private.impact_daily_metrics (
  metric_date,metric_key,metric_value,sample_size,suppressed,quality_status,
  source_window_start,source_window_end
) VALUES (
  '2024-01-15','reach.active_users',5,5,true,'healthy',
  '2024-01-15 00:00:00+00','2024-01-16 00:00:00+00'
);

SET LOCAL role authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"1a400000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);

SELECT lives_ok(
  $q$SELECT * FROM public.admin_impact_metrics('2024-01-01','2024-01-31','overall','all','none')$q$,
  'an active analyst-tier staff boundary can read aggregate metrics');
SELECT is(
  (SELECT suppressed FROM public.admin_impact_metrics('2024-01-01','2024-01-31','overall','all','none') WHERE metric_key='reach.active_users'),
  true,'a five-person cohort is marked suppressed');
SELECT is(
  (SELECT metric_value FROM public.admin_impact_metrics('2024-01-01','2024-01-31','overall','all','none') WHERE metric_key='reach.active_users'),
  NULL::numeric,'a suppressed cohort never returns its value even to super admin');
SELECT is(
  (SELECT status FROM public.admin_impact_methodology() WHERE metric_key='wellbeing.who5'),
  'governance_gated','WHO-5 collection remains technically governance-gated');
SELECT is(
  (SELECT count(*)::integer FROM public.admin_impact_methodology()),
  17,'the phase-one dictionary exposes all defined and gated metrics');

SELECT throws_like(
  $q$SELECT public.admin_generate_impact_report('monthly_impact','No MFA report','internal','2024-01-01','2024-01-31','none',NULL,NULL)$q$,
  '%aal2_required%','report snapshot generation requires an MFA step-up');

SELECT set_config('request.jwt.claims',
  '{"sub":"1a400000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
SELECT lives_ok(
  $q$SELECT public.admin_generate_impact_report('monthly_impact','Verified snapshot','internal','2024-01-01','2024-01-31','none',NULL,'pgTAP')$q$,
  'a stepped-up super admin can generate an immutable aggregate snapshot');
SELECT is(
  (SELECT metric_count FROM public.admin_impact_reports(20)
   WHERE title='Verified snapshot'),
  17,'the snapshot captures the full KPI dictionary, including unavailable metrics');
SELECT ok(
  (SELECT checksum ~ '^[0-9a-f]{64}$' FROM public.admin_impact_reports(20) WHERE title='Verified snapshot'),
  'the snapshot receives a deterministic SHA-256 checksum');
SELECT ok(
  EXISTS (SELECT 1 FROM public.audit_log WHERE action='impact_report_generated' AND target_label='Verified snapshot'),
  'report generation creates a privileged audit entry');
RESET role;

SELECT throws_like(
  $q$UPDATE private.impact_report_values SET title='tampered' WHERE report_id=(SELECT report_id FROM private.impact_report_snapshots WHERE title='Verified snapshot')$q$,
  '%append_only_record%','report values cannot be edited after generation');

INSERT INTO private.impact_programs
  (name,protocol_version,consent_version,purpose,created_by)
VALUES
  ('Consent regression','draft-1','draft-1','Verify that optional impact consent receipts are append-only.',
   '1a400000-0000-4000-8000-000000000001');
INSERT INTO private.impact_participants(program_id,user_id)
SELECT program_id,'1a400000-0000-4000-8000-000000000002'
  FROM private.impact_programs WHERE name='Consent regression';
INSERT INTO private.impact_consent_receipts
  (participant_id,consent_kind,consent_version,granted,source,receipt_hash)
SELECT participant_id,'research_participation','draft-1',true,'app',repeat('a',64)
  FROM private.impact_participants;
SELECT throws_like(
  $q$UPDATE private.impact_consent_receipts SET granted=false$q$,
  '%append_only_record%','research consent history cannot be rewritten; withdrawal requires a new receipt');

SELECT ok(
  EXISTS (SELECT 1 FROM cron.job WHERE jobname='venttly-impact-daily-v1'),
  'the idempotent daily aggregate and quality refresh is scheduled');

SELECT * FROM finish();
ROLLBACK;
