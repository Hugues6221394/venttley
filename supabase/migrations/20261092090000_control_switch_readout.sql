-- One read-out of every release switch, for the super admin Controls panel.
--
-- Each switch already has its own audited, MFA-gated configure RPC; this only
-- reports their current state so the console can show what is on and offer the
-- right next step. Reading needs no step-up; changing still does.
BEGIN;

CREATE FUNCTION public.admin_control_switches() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.is_staff(auth.uid(), ARRAY['super_admin']) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  RETURN jsonb_build_object(
    'staff_inbox', (SELECT jsonb_build_object('enabled', enabled, 'audience_roles', audience_roles,
        'moderation_events', moderation_events_enabled, 'delivery_retention', delivery_retention_enabled,
        'job_events', job_events_enabled, 'report_events', report_events_enabled, 'governance_events', governance_events_enabled)
      FROM private.staff_inbox_control LIMIT 1),
    'access_reviews', (SELECT enabled FROM private.access_review_control LIMIT 1),
    'invitation_ledger', (SELECT jsonb_build_object('enabled', enabled, 'setup_repair', setup_repair_enabled)
      FROM private.staff_invitation_control LIMIT 1),
    'promotion_approvals', (SELECT enabled FROM private.promotion_control LIMIT 1),
    'broadcast_approvals', (SELECT enabled FROM private.broadcast_approval_control LIMIT 1),
    'incidents', (SELECT jsonb_build_object('enabled', enabled, 'notifications', notifications_enabled, 'audience_roles', audience_roles)
      FROM private.incident_control LIMIT 1),
    'active_super_admins', (SELECT count(*) FROM public.users
      WHERE user_role = 'super_admin' AND account_status = 'active' AND deactivated_at IS NULL));
END $$;
REVOKE ALL ON FUNCTION public.admin_control_switches() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.admin_control_switches() TO authenticated;

SELECT public.record_migration('20261092090000', 'control_switch_readout');
COMMIT;
