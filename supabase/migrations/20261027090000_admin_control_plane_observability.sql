-- Aggregate-only read boundary for the twelve operational Super Admin pages.
-- The caller chooses one section; each branch enforces the narrowest existing
-- staff role set and returns no authored content, identities, contact data,
-- tokens, object paths, or raw model reasons.

CREATE OR REPLACE FUNCTION public.admin_control_plane_snapshot(p_section TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $$
DECLARE
  v_actor UUID := (SELECT auth.uid());
  v_result JSONB;
BEGIN
  IF p_section NOT IN (
    'campaigns','support_cases','legal_requests','crisis_playbooks',
    'recovery_readiness','moderation_workforce','model_operations',
    'messaging_operations','storage_operations','regional_compliance',
    'transparency_reports','experiments'
  ) THEN
    RAISE EXCEPTION 'unknown_control_section' USING ERRCODE='22023';
  END IF;

  IF p_section='campaigns' THEN
    IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','moderator']) THEN
      RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
    END IF;
  ELSIF p_section='crisis_playbooks' THEN
    IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','moderator','support']) THEN
      RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
    END IF;
  ELSIF p_section='support_cases' THEN
    IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','support']) THEN
      RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
    END IF;
  ELSIF p_section IN ('transparency_reports','regional_compliance') THEN
    IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','analyst','read_only_auditor']) THEN
      RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
    END IF;
  ELSIF p_section IN ('model_operations','messaging_operations') THEN
    IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin','analyst']) THEN
      RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
    END IF;
  ELSIF p_section IN ('legal_requests','recovery_readiness','storage_operations','experiments') THEN
    IF NOT public.is_staff(v_actor,ARRAY['super_admin','admin']) THEN
      RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
    END IF;
  ELSE
    IF NOT public.is_staff(v_actor,ARRAY['super_admin']) THEN
      RAISE EXCEPTION 'not_authorized' USING ERRCODE='42501';
    END IF;
  END IF;

  IF p_section='campaigns' THEN
    SELECT jsonb_build_object(
      'open_cases',count(*) FILTER (WHERE status NOT IN ('resolved','closed')),
      'high_severity',count(*) FILTER (WHERE severity IN ('high','critical') AND status NOT IN ('resolved','closed')),
      'repeat_subjects',(SELECT count(*) FROM (
        SELECT subject_id FROM public.moderation_cases
         WHERE subject_id IS NOT NULL AND opened_at>=now()-interval '30 days'
         GROUP BY subject_id HAVING count(*)>=3
      ) repeated),
      'high_report_targets',count(*) FILTER (WHERE report_count>=3 AND status NOT IN ('resolved','closed')),
      'window_days',30,
      'campaign_entity_available',false
    ) INTO v_result FROM public.moderation_cases WHERE opened_at>=now()-interval '30 days';

  ELSIF p_section='support_cases' THEN
    SELECT jsonb_build_object(
      'open_appeals',(SELECT count(*) FROM public.moderation_appeals WHERE status NOT IN ('resolved','upheld','denied','closed')),
      'verification_waiting',(SELECT count(*) FROM public.verification_requests WHERE status IN ('pending','in_review','needs_info')),
      'deletion_requests',(SELECT count(*) FROM public.users WHERE deletion_requested_at IS NOT NULL AND deactivated_at IS NULL),
      'unresolved_reports',(SELECT count(*) FROM public.reports WHERE NOT is_resolved),
      'oldest_appeal_hours',COALESCE((SELECT round(extract(epoch FROM (now()-min(created_at)))/3600,1)
        FROM public.moderation_appeals WHERE status NOT IN ('resolved','upheld','denied','closed')),0),
      'dedicated_support_case_entity_available',false
    ) INTO v_result;

  ELSIF p_section='legal_requests' THEN
    SELECT jsonb_build_object(
      'active_legal_holds',(SELECT count(*) FROM public.moderation_cases WHERE legal_hold),
      'privacy_deletion_requests',(SELECT count(*) FROM public.users WHERE deletion_requested_at IS NOT NULL),
      'csam_open',(SELECT count(*) FROM public.csam_incidents WHERE status NOT IN ('closed','reported')),
      'audited_evidence_access_30d',(SELECT count(*) FROM public.audit_log WHERE action ILIKE '%evidence%' AND created_at>=now()-interval '30 days'),
      'legal_request_entity_available',false,
      'external_disclosure_workflow_available',false
    ) INTO v_result;

  ELSIF p_section='crisis_playbooks' THEN
    SELECT jsonb_build_object(
      'flagged_vents_24h',(SELECT count(*) FROM public.posts WHERE crisis_level IS NOT NULL AND created_at>=now()-interval '24 hours'),
      'flagged_whispers_24h',(SELECT count(*) FROM public.whispers WHERE crisis_level IS NOT NULL AND created_at>=now()-interval '24 hours'),
      'flagged_messages_24h',(SELECT
        (SELECT count(*) FROM public.tribe_messages WHERE crisis_level IS NOT NULL AND created_at>=now()-interval '24 hours')+
        (SELECT count(*) FROM public.chat_messages WHERE crisis_level IS NOT NULL AND created_at>=now()-interval '24 hours')),
      'critical_open_cases',(SELECT count(*) FROM public.moderation_cases WHERE severity='critical' AND status NOT IN ('resolved','closed')),
      'published_resources',(SELECT count(*) FROM public.crisis_resources),
      'playbook_acknowledgement_available',false
    ) INTO v_result;

  ELSIF p_section='recovery_readiness' THEN
    SELECT jsonb_build_object(
      'accounts_total',count(*),
      'recovery_phrase_ready',count(*) FILTER (WHERE recovery_key_hash IS NOT NULL),
      'verified_recovery_email',count(*) FILTER (WHERE recovery_email_verified),
      'verified_recovery_phone',count(*) FILTER (WHERE recovery_phone_verified),
      'pending_recovery_email',count(*) FILTER (WHERE recovery_email_pending IS NOT NULL),
      'password_changes_30d',count(*) FILTER (WHERE password_changed_at>=now()-interval '30 days'),
      'restore_drill_evidence_available',false
    ) INTO v_result FROM public.users;

  ELSIF p_section='moderation_workforce' THEN
    SELECT jsonb_build_object(
      'active_super_admins',(SELECT count(*) FROM public.users WHERE user_role::TEXT='super_admin' AND account_status='active' AND deactivated_at IS NULL),
      'active_admins',(SELECT count(*) FROM public.users WHERE user_role::TEXT='admin' AND account_status='active' AND deactivated_at IS NULL),
      'active_moderators',(SELECT count(*) FROM public.users WHERE user_role::TEXT='moderator' AND account_status='active' AND deactivated_at IS NULL),
      'active_support',(SELECT count(*) FROM public.users WHERE user_role::TEXT='support' AND account_status='active' AND deactivated_at IS NULL),
      'open_unassigned_cases',(SELECT count(*) FROM public.moderation_cases WHERE assignee_id IS NULL AND status NOT IN ('resolved','closed')),
      'open_assigned_cases',(SELECT count(*) FROM public.moderation_cases WHERE assignee_id IS NOT NULL AND status NOT IN ('resolved','closed')),
      'sla_breached_open',(SELECT count(*) FROM public.moderation_cases WHERE sla_due_at<now() AND status NOT IN ('resolved','closed')),
      'shift_roster_available',false
    ) INTO v_result;

  ELSIF p_section='model_operations' THEN
    SELECT jsonb_build_object(
      'cached_verdicts',count(*),
      'total_lookups',COALESCE(sum(hit_count),0),
      'safe_verdicts',count(*) FILTER (WHERE verdict='safe'),
      'warn_verdicts',count(*) FILTER (WHERE verdict='warn'),
      'block_verdicts',count(*) FILTER (WHERE verdict='block'),
      'crisis_verdicts',count(*) FILTER (WHERE crisis),
      'classifier_versions',count(DISTINCT classifier_version),
      'last_verdict_at',max(last_seen_at),
      'evaluation_dataset_available',false
    ) INTO v_result FROM public.moderation_verdicts;

  ELSIF p_section='messaging_operations' THEN
    SELECT jsonb_build_object(
      'push_queued',(SELECT count(*) FROM public.push_delivery_outbox WHERE status IN ('queued','pending','retry')),
      'push_failed',(SELECT count(*) FROM public.push_delivery_outbox WHERE status='failed'),
      'push_sent_24h',(SELECT count(*) FROM public.push_delivery_outbox WHERE status='sent' AND sent_at>=now()-interval '24 hours'),
      'email_queued',(SELECT count(*) FROM public.email_outbox WHERE status IN ('queued','sending')),
      'email_failed',(SELECT count(*) FROM public.email_outbox WHERE status='failed'),
      'email_sent_24h',(SELECT count(*) FROM public.email_outbox WHERE status='sent' AND sent_at>=now()-interval '24 hours'),
      'notifications_created_24h',(SELECT count(*) FROM public.notifications WHERE created_at>=now()-interval '24 hours'),
      'provider_delivery_receipts_available',false
    ) INTO v_result;

  ELSIF p_section='storage_operations' THEN
    SELECT jsonb_build_object(
      'buckets',(SELECT count(*) FROM storage.buckets),
      'object_row_estimate',COALESCE((SELECT n_live_tup::BIGINT FROM pg_catalog.pg_stat_all_tables WHERE schemaname='storage' AND relname='objects'),0),
      'pending_media_scans',(SELECT count(*) FROM public.media_scan_jobs WHERE completed_at IS NULL),
      'leased_media_scans',(SELECT count(*) FROM public.media_scan_jobs WHERE completed_at IS NULL AND lease_expires_at>now()),
      'quarantined_vents',(SELECT count(*) FROM public.posts WHERE media_status IN ('pending','blocked','sensitive')),
      'quarantined_whispers',(SELECT count(*) FROM public.whispers WHERE media_status IN ('pending','blocked','sensitive')),
      'byte_usage_telemetry_available',false,
      'orphan_scan_available',false
    ) INTO v_result;

  ELSIF p_section='regional_compliance' THEN
    SELECT jsonb_build_object(
      'declared_residence_coverage',count(*) FILTER (WHERE home_country IS NOT NULL AND btrim(home_country)<>''),
      'declared_residence_countries',count(DISTINCT upper(home_country)) FILTER (WHERE home_country IS NOT NULL AND btrim(home_country)<>''),
      'technical_signal_coverage',count(*) FILTER (WHERE last_country IS NOT NULL AND btrim(last_country)<>''),
      'technical_signal_countries',count(DISTINCT upper(last_country)) FILTER (WHERE last_country IS NOT NULL AND btrim(last_country)<>''),
      'minor_accounts',count(*) FILTER (WHERE birth_year IS NOT NULL AND extract(year FROM age(make_date(birth_year,COALESCE(birth_month,7),1)))<18),
      'policy_acceptances',(SELECT count(*) FROM public.policy_acceptances),
      'current_residence_collected',false,
      'nationality_collected',false,
      'technical_signal_is_residence',false
    ) INTO v_result FROM public.users;

  ELSIF p_section='transparency_reports' THEN
    SELECT jsonb_build_object(
      'reports_received_30d',(SELECT count(*) FROM public.reports WHERE created_at>=now()-interval '30 days'),
      'reports_resolved_30d',(SELECT count(*) FROM public.reports WHERE is_resolved AND resolved_at>=now()-interval '30 days'),
      'cases_decided_30d',(SELECT count(*) FROM public.moderation_cases WHERE decided_at>=now()-interval '30 days'),
      'appeals_received_30d',(SELECT count(*) FROM public.moderation_appeals WHERE created_at>=now()-interval '30 days'),
      'appeals_completed_30d',(SELECT count(*) FROM public.moderation_appeals WHERE reviewed_at>=now()-interval '30 days'),
      'immutable_impact_reports',(SELECT count(*) FROM private.impact_report_snapshots),
      'published_impact_reports',(SELECT count(*) FROM private.impact_report_snapshots WHERE status='published')
    ) INTO v_result;

  ELSE -- experiments
    SELECT jsonb_build_object(
      'flags_total',count(*),
      'flags_enabled',count(*) FILTER (WHERE enabled),
      'partial_rollouts',count(*) FILTER (WHERE enabled AND rollout_pct BETWEEN 1 AND 99),
      'full_rollouts',count(*) FILTER (WHERE enabled AND rollout_pct=100),
      'disabled',count(*) FILTER (WHERE NOT enabled OR rollout_pct=0),
      'overrides',(SELECT count(*) FROM public.feature_flag_overrides),
      'guardrail_metric_linkage_available',false,
      'automatic_stop_rules_available',false
    ) INTO v_result FROM public.feature_flags;
  END IF;

  RETURN jsonb_build_object(
    'section',p_section,
    'generated_at',now(),
    'privacy','aggregate_only',
    'data',COALESCE(v_result,'{}'::JSONB)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_control_plane_snapshot(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_control_plane_snapshot(TEXT) TO authenticated;

COMMENT ON FUNCTION public.admin_control_plane_snapshot(TEXT) IS
  'Aggregate-only, section-authorized operational snapshot. Never returns user identity, authored content, provider tokens, object paths, or model explanations.';

NOTIFY pgrst, 'reload schema';
