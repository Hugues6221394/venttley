import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice } from "@/components/ui/operations";
import { Siren } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Signal = {
  label: string;
  value: number | null;
  href: string;
  explanation: string;
};

export default async function IncidentsPage() {
  const db = await createAdminClient();
  const staleBefore = new Date(Date.now() - 15 * 60 * 1000).toISOString();
  const [csam, crisis, sla, deadPush, failedEmail, staleMedia, criticalSecurity] = await Promise.all([
    db.from("csam_incidents").select("incident_id", { count: "exact", head: true }).eq("status", "open"),
    db.from("posts").select("post_id", { count: "exact", head: true }).not("crisis_level", "is", null).is("deleted_at", null),
    db.from("moderation_cases").select("case_id", { count: "exact", head: true }).not("sla_breached_at", "is", null).neq("status", "resolved"),
    db.from("push_delivery_outbox").select("delivery_id", { count: "exact", head: true }).eq("status", "dead"),
    db.from("email_outbox").select("outbox_id", { count: "exact", head: true }).eq("status", "failed"),
    db.from("media_scan_jobs").select("content_id", { count: "exact", head: true }).is("completed_at", null).lt("created_at", staleBefore),
    db.from("security_events").select("event_id", { count: "exact", head: true }).eq("severity", "critical").gte("created_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()),
  ]);
  const raw = [csam, crisis, sla, deadPush, failedEmail, staleMedia, criticalSecurity];
  const errors = raw.flatMap((result) => result.error ? [result.error.message] : []);
  const signals: Signal[] = [
    { label: "Open CSAM incidents", value: csam.count, href: "/incidents/csam-open", explanation: "Quarantined child-safety incidents requiring the restricted evidence workflow." },
    { label: "Crisis-flagged Vents", value: crisis.count, href: "/incidents/crisis-posts", explanation: "Published crisis signals that may require safety-team response." },
    { label: "Breached moderation SLAs", value: sla.count, href: "/incidents/moderation-sla", explanation: "Unresolved cases whose persisted response deadline has passed." },
    { label: "Dead push deliveries", value: deadPush.count, href: "/incidents/push-dead", explanation: "Push work that exhausted its current delivery path." },
    { label: "Failed email deliveries", value: failedEmail.count, href: "/incidents/email-failed", explanation: "Email work marked failed by the dispatcher." },
    { label: "Media scans stale 15m+", value: staleMedia.count, href: "/incidents/media-stale", explanation: "Unfinished scan jobs old enough to indicate a stuck pipeline." },
    { label: "Critical security events · 24h", value: criticalSecurity.count, href: "/incidents/security-critical", explanation: "High-severity member security events in the last day." },
  ];
  const knownAttention = signals.reduce((sum, signal) => sum + (signal.value ?? 0), 0);
  const posture = errors.length > 0 ? "unknown" : knownAttention > 0 ? "attention required" : "quiet";

  return (
    <div className="flex max-w-[1100px] flex-col gap-6">
      <PageHeader eyebrow="Operate" title="Incident command" subtitle="A single entry point for safety, security, and delivery signals. It reports what the current systems can prove and never converts query failures into green status." />
      <Card>
        <div className="flex flex-wrap items-center gap-3"><Siren size={20} className={posture === "quiet" ? "text-ok" : "text-danger"} /><p className="text-lg font-extrabold text-burgundy">Current posture</p><Badge tone={posture === "quiet" ? "ok" : posture === "unknown" ? "neutral" : "danger"}>{posture}</Badge></div>
        <p className="mt-2 text-xs text-ink-muted">{posture === "quiet" ? "No active signals were returned. This is not a substitute for external uptime, provider, or client-crash monitoring." : posture === "unknown" ? "At least one required data source failed, so the console cannot make a reliable incident assessment." : `${knownAttention.toLocaleString()} active signal${knownAttention === 1 ? "" : "s"} need triage across the linked work queues.`}</p>
      </Card>
      {errors.length > 0 && <ErrorPanel title="Incident picture is incomplete" detail={errors.join("\n")} />}
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        {signals.map((signal) => <Link href={signal.href} key={signal.label} className="surface p-5 transition hover:border-berry/40"><div className="flex items-center justify-between gap-3"><p className="font-bold text-burgundy">{signal.label}</p><span className="text-2xl font-extrabold text-burgundy">{signal.value ?? "—"}</span></div><p className="mt-2 text-xs leading-relaxed text-ink-muted">{signal.explanation}</p></Link>)}
      </div>
      <CapabilityNotice title="This is signal routing, not yet incident lifecycle management">
        Declaring, assigning, updating, resolving, and reviewing an incident
        requires a dedicated append-only incident model, severity policy,
        communications log, postmortem workflow, and rollback/runbook links.
        Those controls remain unavailable until the backend phase.
      </CapabilityNotice>
    </div>
  );
}
