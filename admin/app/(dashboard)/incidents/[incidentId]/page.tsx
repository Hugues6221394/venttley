import Link from "next/link";
import { notFound } from "next/navigation";
import { activeStaffRole } from "@/lib/staff";
import { createAdminClient, createSsrClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { Siren } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type IncidentRow = {
  id: string;
  title: string;
  status: string;
  detail: string;
  time: string;
  href: string;
};

const INCIDENTS = {
  "csam-open": { title: "Open child-safety incidents", severity: "critical", owner: "Child-safety lead", runbook: "Keep media quarantined. Use the restricted evidence workflow and record external report references where legally required." },
  "crisis-posts": { title: "Crisis-flagged Vents", severity: "critical", owner: "Safety response", runbook: "Review severity promptly, offer localized crisis resources, and avoid punitive enforcement for help-seeking speech." },
  "moderation-sla": { title: "Breached moderation SLAs", severity: "high", owner: "Moderation lead", runbook: "Assign an accountable reviewer, prioritize by severity, and document the first meaningful action." },
  "push-dead": { title: "Dead push deliveries", severity: "high", owner: "Platform operations", runbook: "Confirm provider health and token validity before replay. Never retry a non-idempotent fanout blindly." },
  "email-failed": { title: "Failed email deliveries", severity: "high", owner: "Platform operations", runbook: "Check provider response classes, sender reputation, and template configuration without exposing recipient addresses." },
  "media-stale": { title: "Stale media scans", severity: "critical", owner: "Trust infrastructure", runbook: "Keep affected media quarantined, restore scanner throughput, and replay only through lease-safe worker contracts." },
  "security-critical": { title: "Critical account-security events", severity: "critical", owner: "Security response", runbook: "Review affected accounts and sessions, preserve audit evidence, and use narrowly scoped containment controls." },
} as const;

type IncidentKey = keyof typeof INCIDENTS;

export default async function IncidentDetailPage({ params }: { params: Promise<{ incidentId: string }> }) {
  const { incidentId } = await params;
  if (!(incidentId in INCIDENTS)) notFound();
  const key = incidentId as IncidentKey;
  const definition = INCIDENTS[key];
  // The parent incident router is available to admins, but CSAM record-level
  // visibility follows the stricter /csam boundary. The service-role client
  // below bypasses RLS, so this narrower check must happen before creating it.
  if (key === "csam-open") {
    const ssr = await createSsrClient();
    const { data: { user } } = await ssr.auth.getUser();
    if (!user || await activeStaffRole(ssr, user.id, ["super_admin"]) !== "super_admin") notFound();
  }
  const db = await createAdminClient();
  const staleBefore = new Date(Date.now() - 15 * 60 * 1000).toISOString();
  const dayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

  let rows: IncidentRow[] = [];
  let error: string | null = null;
  let total: number | null = null;

  if (key === "csam-open") {
    const result = await db.from("csam_incidents").select("incident_id, kind, status, detected_at", { count: "exact" }).eq("status", "open").order("detected_at").limit(100);
    error = result.error?.message ?? null; total = result.count;
    rows = (result.data ?? []).map((row) => ({ id: row.incident_id, title: row.kind.replaceAll("_", " "), status: row.status, detail: "Evidence remains sealed until an AAL2 reason-required reveal.", time: row.detected_at, href: `/csam?incident=${row.incident_id}` }));
  } else if (key === "crisis-posts") {
    const result = await db.from("posts").select("post_id, crisis_level, created_at", { count: "exact" }).not("crisis_level", "is", null).is("deleted_at", null).order("created_at").limit(100);
    error = result.error?.message ?? null; total = result.count;
    rows = (result.data ?? []).map((row) => ({ id: row.post_id, title: "Crisis-flagged Vent", status: row.crisis_level ?? "flagged", detail: "Authored text is withheld from this incident index; open the safety queue for scoped review.", time: row.created_at, href: "/safety" }));
  } else if (key === "moderation-sla") {
    const result = await db.from("moderation_cases").select("case_id, severity, policy_code, status, sla_breached_at", { count: "exact" }).neq("status", "resolved").not("sla_breached_at", "is", null).order("sla_breached_at").limit(100);
    error = result.error?.message ?? null; total = result.count;
    rows = (result.data ?? []).map((row) => ({ id: row.case_id, title: row.policy_code ?? "Unclassified policy", status: `${row.severity} · ${row.status}`, detail: "Persisted moderation deadline breached.", time: row.sla_breached_at!, href: `/moderation/cases/${row.case_id}` }));
  } else if (key === "push-dead") {
    const result = await db.from("push_delivery_outbox").select("delivery_id, event_kind, status, attempts, last_error_code, created_at", { count: "exact" }).eq("status", "dead").order("created_at").limit(100);
    error = result.error?.message ?? null; total = result.count;
    rows = (result.data ?? []).map((row) => ({ id: row.delivery_id, title: row.event_kind, status: `${row.status} · ${row.attempts} attempts`, detail: row.last_error_code ?? "No provider error code recorded", time: row.created_at, href: "/jobs" }));
  } else if (key === "email-failed") {
    const result = await db.from("email_outbox").select("outbox_id, template, status, attempts, last_error, created_at", { count: "exact" }).eq("status", "failed").order("created_at").limit(100);
    error = result.error?.message ?? null; total = result.count;
    rows = (result.data ?? []).map((row) => ({ id: row.outbox_id, title: row.template, status: `${row.status} · ${row.attempts} attempts`, detail: row.last_error?.slice(0, 180) ?? "No provider error recorded", time: row.created_at, href: "/jobs" }));
  } else if (key === "media-stale") {
    const result = await db.from("media_scan_jobs").select("kind, content_id, attempts, created_at", { count: "exact" }).is("completed_at", null).lt("created_at", staleBefore).order("created_at").limit(100);
    error = result.error?.message ?? null; total = result.count;
    rows = (result.data ?? []).map((row) => ({ id: `${row.kind}:${row.content_id}`, title: `${row.kind.replaceAll("_", " ")} scan`, status: `${row.attempts} attempts`, detail: `Content reference ${row.content_id.slice(0, 8)}…`, time: row.created_at, href: "/jobs" }));
  } else {
    const result = await db.from("security_events").select("event_id, user_id, kind, severity, created_at", { count: "exact" }).eq("severity", "critical").gte("created_at", dayAgo).order("created_at").limit(100);
    error = result.error?.message ?? null; total = result.count;
    rows = (result.data ?? []).map((row) => ({ id: row.event_id, title: row.kind.replaceAll("_", " "), status: row.severity, detail: "Sensitive event context is intentionally omitted from this overview.", time: row.created_at, href: `/users/${row.user_id}` }));
  }

  return (
    <div className="flex max-w-[1100px] flex-col gap-6">
      <PageHeader eyebrow="Incident signal" title={definition.title} subtitle={`${definition.owner} · point-in-time operational dossier`} actions={<Link href="/incidents" className="btn-secondary">All incident signals</Link>} />
      <DataWarning title="Signal group, not a persistent incident record">
        This URL identifies a live query, not an immutable incident ID. Assignment,
        acknowledgements, mitigation history, communications, and resolution do
        not yet exist as a canonical state machine.
      </DataWarning>
      {error && <ErrorPanel title="Incident signal could not be loaded" detail={error} />}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Card><p className="h-eyebrow">Severity</p><div className="mt-2"><Badge tone={definition.severity === "critical" ? "danger" : "warn"}>{definition.severity}</Badge></div></Card>
        <Card><p className="h-eyebrow">Known records</p><p className="mt-1 text-3xl font-extrabold text-burgundy">{total ?? "—"}</p></Card>
        <Card><p className="h-eyebrow">Accountable team</p><p className="mt-2 text-sm font-bold text-burgundy">{definition.owner}</p></Card>
      </div>
      <Card title="Immediate runbook" hint="Operator guidance; not automated execution"><p className="text-sm leading-relaxed text-burgundy">{definition.runbook}</p></Card>
      <Card title="Current records" hint={`Oldest first · showing up to ${rows.length}`} padded={false}>
        {rows.length === 0 ? <EmptyState icon={<Siren size={32} />} title="No records returned." hint={error ? "The source failed, so status is unknown." : "This signal is currently quiet."} /> : (
          <ul className="divide-y divide-line">
            {rows.map((row) => <li key={row.id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><p className="font-bold text-burgundy">{row.title}</p><Badge tone="warn">{row.status}</Badge><time className="ml-auto text-[11px] text-ink-muted">{new Date(row.time).toLocaleString()}</time></div><p className="mt-1 text-xs text-ink-muted">{row.detail}</p><Link href={row.href} className="mt-1 inline-block text-xs font-bold text-berry hover:underline">Open owning workflow</Link></li>)}
          </ul>
        )}
      </Card>
      <CapabilityNotice title="Incident lifecycle backend is still required">
        The next phase must add an append-only incident model with declaration,
        ownership, acknowledgements, severity changes, mitigations, linked kill
        switches, communications, resolution, and post-incident review.
      </CapabilityNotice>
    </div>
  );
}
