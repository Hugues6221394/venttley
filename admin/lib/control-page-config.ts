import type { ControlPageConfig } from "@/components/control-plane-page";

export const controlPages = {
  campaigns: {
    section: "campaigns",
    eyebrow: "Trust & Safety",
    title: "Coordinated harm campaigns",
    subtitle: "Aggregate signals for repeated subjects and heavily reported targets. These are triage indicators, not proof of coordination.",
    metrics: [
      { key: "open_cases", label: "Open cases · 30d", sub: "All unresolved cases", tone: "info" },
      { key: "high_severity", label: "High severity", sub: "High or critical and open", tone: "danger" },
      { key: "repeat_subjects", label: "Repeat subjects", sub: "3+ cases in 30 days", tone: "warn" },
      { key: "high_report_targets", label: "Repeatedly reported", sub: "3+ reports and open", tone: "warn" },
    ],
    capabilities: [
      { key: "campaign_entity_available", label: "Campaign case entity", consequence: "Signals cannot yet be grouped, assigned, versioned, or closed as one investigation." },
    ],
    operatingChecks: [
      "Corroborate across multiple independent signals before labelling activity coordinated.",
      "Keep person-level evidence inside the existing moderation case boundary.",
      "Escalate critical safety or CSAM indicators through their dedicated workflows.",
    ],
    links: [{ href: "/moderation", label: "Open case queue" }, { href: "/integrity", label: "Integrity signals" }],
  },
  support_cases: {
    section: "support_cases",
    eyebrow: "Member Operations",
    title: "Support cases",
    subtitle: "One workload view across appeals, verification, deletion requests, and unresolved reports without exposing private submissions on the overview.",
    metrics: [
      { key: "open_appeals", label: "Open appeals", sub: "Awaiting final outcome", tone: "warn" },
      { key: "verification_waiting", label: "Verification waiting", sub: "Pending, review, or more info", tone: "info" },
      { key: "deletion_requests", label: "Deletion requests", sub: "Requested and not deactivated", tone: "danger" },
      { key: "oldest_appeal_hours", label: "Oldest appeal", sub: "Queue age", tone: "warn", format: "hours" },
    ],
    capabilities: [
      { key: "dedicated_support_case_entity_available", label: "Unified support case record", consequence: "Cross-workflow ownership, SLA, correspondence, and escalation are not yet canonical." },
    ],
    operatingChecks: [
      "Treat deletion and safety requests as different workflows with different disclosure rules.",
      "Do not copy authored content into support notes or external ticketing tools.",
      "Use the source workflow for decisions so its audit and authorization rules remain intact.",
    ],
    links: [{ href: "/appeals", label: "Appeals" }, { href: "/verification", label: "Verification" }, { href: "/privacy", label: "Privacy requests" }],
  },
  legal_requests: {
    section: "legal_requests",
    eyebrow: "Governance",
    title: "Legal requests",
    subtitle: "Readiness view for legal holds, privacy requests, and evidence access. It is not a substitute for counsel or a disclosure workflow.",
    metrics: [
      { key: "active_legal_holds", label: "Active legal holds", sub: "Case evidence protected", tone: "danger" },
      { key: "privacy_deletion_requests", label: "Deletion requests", sub: "All pending requests", tone: "warn" },
      { key: "csam_open", label: "Open CSAM incidents", sub: "Restricted response path", tone: "crisis" },
      { key: "audited_evidence_access_30d", label: "Evidence access · 30d", sub: "Audit events only", tone: "info" },
    ],
    capabilities: [
      { key: "legal_request_entity_available", label: "Canonical legal request case", consequence: "Deadlines, jurisdiction, requester validation, and approvals are not yet a dedicated record." },
      { key: "external_disclosure_workflow_available", label: "Two-person disclosure workflow", consequence: "No production path should export user data until this is built and counsel-approved." },
    ],
    operatingChecks: [
      "Verify jurisdiction and requester authority outside the application before any disclosure.",
      "Require legal review and two-person approval for exports.",
      "Preserve applicable holds without defeating valid deletion obligations.",
    ],
    links: [{ href: "/data-governance", label: "Data governance" }, { href: "/evidence-access", label: "Evidence access" }],
  },
  crisis_playbooks: {
    section: "crisis_playbooks",
    eyebrow: "Safety Operations",
    title: "Crisis playbooks",
    subtitle: "Real-time crisis-signal load and resource readiness. Classifier signals are not diagnoses and never replace human judgement.",
    metrics: [
      { key: "flagged_vents_24h", label: "Flagged Vents · 24h", sub: "Elevated or high signal", tone: "danger" },
      { key: "flagged_whispers_24h", label: "Flagged Whispers · 24h", sub: "Elevated or high signal", tone: "danger" },
      { key: "flagged_messages_24h", label: "Flagged messages · 24h", sub: "Tribe and direct chat", tone: "danger" },
      { key: "published_resources", label: "Published resources", sub: "Regional and global help", tone: "ok" },
    ],
    capabilities: [
      { key: "playbook_acknowledgement_available", label: "Playbook acknowledgement and drills", consequence: "Operators cannot yet attest to the current playbook or record drill evidence." },
    ],
    operatingChecks: [
      "Prioritize imminent-harm signals and document each escalation decision.",
      "Show locally appropriate resources without claiming clinical care.",
      "Never expose a person-level well-being score or crisis history in aggregate reporting.",
    ],
    links: [{ href: "/safety", label: "Safety queue" }, { href: "/incidents", label: "Incident command" }],
  },
  recovery_readiness: {
    section: "recovery_readiness",
    eyebrow: "Resilience",
    title: "Recovery readiness",
    subtitle: "Account-recovery coverage and evidence gaps. Coverage does not prove that backup restoration or recovery delivery works end to end.",
    metrics: [
      { key: "recovery_phrase_ready", label: "Recovery phrase ready", sub: "Has server-side verifier", tone: "ok" },
      { key: "verified_recovery_email", label: "Verified email", sub: "Optional recovery method", tone: "info" },
      { key: "verified_recovery_phone", label: "Verified phone", sub: "Optional recovery method", tone: "info" },
      { key: "pending_recovery_email", label: "Pending email", sub: "Verification incomplete", tone: "warn" },
    ],
    capabilities: [
      { key: "restore_drill_evidence_available", label: "Database restore evidence", consequence: "This page has no automated proof of backup freshness, restore time, or restored-data integrity." },
    ],
    operatingChecks: [
      "Run scheduled restore drills in an isolated environment and record RTO/RPO evidence.",
      "Test every configured recovery method against current Auth behaviour.",
      "Alert on recovery delivery failure without logging addresses, phone numbers, or secrets.",
    ],
    links: [{ href: "/security", label: "Security center" }, { href: "/system", label: "System health" }],
  },
  moderation_workforce: {
    section: "moderation_workforce",
    eyebrow: "Workforce Safety",
    title: "Moderation workforce",
    subtitle: "Aggregate staffing and queue ownership. Individual productivity ranking is intentionally absent because it encourages unsafe moderation behaviour.",
    metrics: [
      { key: "active_moderators", label: "Active moderators", sub: "Accounts in good standing", tone: "info" },
      { key: "active_support", label: "Active support", sub: "Accounts in good standing", tone: "info" },
      { key: "open_unassigned_cases", label: "Unassigned cases", sub: "Open and unowned", tone: "warn" },
      { key: "sla_breached_open", label: "SLA breached", sub: "Open cases past due", tone: "danger" },
    ],
    capabilities: [
      { key: "shift_roster_available", label: "Coverage and shift roster", consequence: "Timezone coverage, workload caps, breaks, and on-call ownership are not yet represented." },
    ],
    operatingChecks: [
      "Balance queue age and severity rather than raw decision volume.",
      "Limit repeated exposure to distressing content and provide escalation support.",
      "Review access immediately when a staff account is suspended or changes role.",
    ],
    links: [{ href: "/staff", label: "Staff accounts" }, { href: "/slo", label: "Service levels" }],
  },
  model_operations: {
    section: "model_operations",
    eyebrow: "Safety Infrastructure",
    title: "Model operations",
    subtitle: "Classifier mix, cache health, and version visibility. Verdict counts do not establish model quality or fairness.",
    metrics: [
      { key: "cached_verdicts", label: "Cached verdicts", sub: "Distinct content hashes", tone: "info" },
      { key: "total_lookups", label: "Total lookups", sub: "Classifications plus hits" },
      { key: "block_verdicts", label: "Block verdicts", sub: "Cached block outcomes", tone: "danger" },
      { key: "classifier_versions", label: "Classifier versions", sub: "Observed in cache", tone: "warn" },
    ],
    capabilities: [
      { key: "evaluation_dataset_available", label: "Versioned evaluation and bias suite", consequence: "Precision, recall, subgroup error, drift, and rollback gates are not yet evidenced." },
    ],
    operatingChecks: [
      "Compare releases on a consent-safe, versioned evaluation corpus before rollout.",
      "Track false positives and false negatives by safe cohorts, never by authored content in analytics.",
      "Keep a kill switch and previous model version ready for immediate rollback.",
    ],
    links: [{ href: "/automod", label: "Automod rules" }, { href: "/releases", label: "Release readiness" }],
  },
  messaging_operations: {
    section: "messaging_operations",
    eyebrow: "Delivery",
    title: "Messaging operations",
    subtitle: "Push, email, and in-app notification delivery queues without recipient addresses or notification content.",
    metrics: [
      { key: "push_queued", label: "Push queued", sub: "Pending or retry", tone: "warn" },
      { key: "push_failed", label: "Push failed", sub: "Terminal failures", tone: "danger" },
      { key: "email_queued", label: "Email queued", sub: "Queued or sending", tone: "warn" },
      { key: "email_failed", label: "Email failed", sub: "Terminal failures", tone: "danger" },
    ],
    capabilities: [
      { key: "provider_delivery_receipts_available", label: "Provider delivery receipts", consequence: "Queued/sent state is not end-device delivery; provider receipts and outcome SLOs remain a gap." },
    ],
    operatingChecks: [
      "Measure user-visible delivery outcomes, not only successful enqueue.",
      "Retry idempotently and dead-letter poison events without duplicate messages.",
      "Never include Vent, Whisper, or chat previews in external push payloads.",
    ],
    links: [{ href: "/delivery", label: "Delivery overview" }, { href: "/jobs", label: "Jobs" }],
  },
  storage_operations: {
    section: "storage_operations",
    eyebrow: "Infrastructure",
    title: "Storage operations",
    subtitle: "Bucket inventory, estimated object volume, quarantine pressure, and explicitly unevidenced capacity controls.",
    metrics: [
      { key: "buckets", label: "Buckets", sub: "Configured storage domains", tone: "info" },
      { key: "object_row_estimate", label: "Object estimate", sub: "Planner estimate, not billing", tone: "neutral" },
      { key: "pending_media_scans", label: "Pending scans", sub: "Not yet completed", tone: "warn" },
      { key: "quarantined_vents", label: "Quarantined Vents", sub: "Pending, blocked, or sensitive", tone: "danger" },
    ],
    capabilities: [
      { key: "byte_usage_telemetry_available", label: "Byte usage and growth forecast", consequence: "Object-row estimates do not measure bytes, egress, cost, or capacity headroom." },
      { key: "orphan_scan_available", label: "Orphan and retention scanner", consequence: "Unreferenced objects and expired data are not yet proved deleted." },
    ],
    operatingChecks: [
      "Keep uploads quarantined until scanning reaches a terminal safe state.",
      "Validate bucket policies and path ownership after every storage migration.",
      "Reconcile database references, object inventory, lifecycle rules, and restore samples.",
    ],
    links: [{ href: "/media", label: "Media safety" }, { href: "/data-governance", label: "Retention controls" }],
  },
  regional_compliance: {
    section: "regional_compliance",
    eyebrow: "Governance",
    title: "Regional compliance",
    subtitle: "Country-source coverage and policy readiness. Technical country signals are shown separately and are never described as residence or nationality.",
    metrics: [
      { key: "declared_residence_coverage", label: "Declared coverage", sub: "User-provided home country", tone: "info" },
      { key: "technical_signal_coverage", label: "Technical coverage", sub: "Coarse edge country", tone: "neutral" },
      { key: "minor_accounts", label: "Minor accounts", sub: "Age-rule cohort", tone: "warn" },
      { key: "policy_acceptances", label: "Policy acceptances", sub: "Versioned receipts", tone: "ok" },
    ],
    capabilities: [
      { key: "current_residence_collected", label: "Declared current residence", consequence: "Not collected; do not infer it from IP or home-country profile data." },
      { key: "nationality_collected", label: "Nationality", consequence: "Not collected and not required for current product operation." },
      { key: "technical_signal_is_residence", label: "Technical signal as residence", consequence: "Correctly disabled: edge country is a coarse technical signal only." },
    ],
    operatingChecks: [
      "Review age, consent, retention, transfer, and reporting obligations per launch country.",
      "Document the source and purpose of every geography field.",
      "Suppress small country cohorts in all impact and transparency outputs.",
    ],
    links: [{ href: "/policy/versions", label: "Policy versions" }, { href: "/impact/geography", label: "Impact geography" }],
  },
  transparency_reports: {
    section: "transparency_reports",
    eyebrow: "Accountability",
    title: "Transparency reports",
    subtitle: "Aggregate moderation, appeal, and immutable impact-report evidence for internal review and future public reporting.",
    metrics: [
      { key: "reports_received_30d", label: "Reports · 30d", sub: "User-submitted reports", tone: "info" },
      { key: "cases_decided_30d", label: "Cases decided · 30d", sub: "Recorded decisions", tone: "ok" },
      { key: "appeals_received_30d", label: "Appeals · 30d", sub: "Review demand", tone: "warn" },
      { key: "immutable_impact_reports", label: "Impact snapshots", sub: "Checksum-protected reports", tone: "info" },
    ],
    capabilities: [],
    operatingChecks: [
      "Publish only immutable snapshots with metric definitions and reporting windows attached.",
      "Explain missing data, cohort suppression, uncertainty, and methodology changes.",
      "Never publish raw content, identities, exact locations, or low-volume cohorts.",
    ],
    links: [{ href: "/impact/reports", label: "Impact reports" }, { href: "/slo", label: "Service levels" }],
  },
  experiments: {
    section: "experiments",
    eyebrow: "Product Governance",
    title: "Experiments",
    subtitle: "Feature rollout inventory and governance gaps. A percentage flag is not, by itself, a controlled or ethical experiment.",
    metrics: [
      { key: "flags_total", label: "Feature flags", sub: "All environments", tone: "info" },
      { key: "flags_enabled", label: "Enabled", sub: "Any active rollout", tone: "ok" },
      { key: "partial_rollouts", label: "Partial rollouts", sub: "1–99% exposure", tone: "warn" },
      { key: "overrides", label: "Targeted overrides", sub: "User or Tribe exceptions", tone: "warn" },
    ],
    capabilities: [
      { key: "guardrail_metric_linkage_available", label: "Guardrail metric linkage", consequence: "Rollouts are not yet tied to safety, reliability, or impact guardrails." },
      { key: "automatic_stop_rules_available", label: "Automatic stop rules", consequence: "No automatic rollback occurs when a guardrail breaches." },
    ],
    operatingChecks: [
      "Define hypothesis, exposure unit, primary metric, safety guardrails, and stopping rule before rollout.",
      "Exclude sensitive cohorts or research claims unless consent and governance explicitly allow them.",
      "Maintain a kill switch and record every rollout change in the privileged audit log.",
    ],
    links: [{ href: "/flags", label: "Feature flags" }, { href: "/releases", label: "Release readiness" }],
  },
} satisfies Record<string, ControlPageConfig>;
