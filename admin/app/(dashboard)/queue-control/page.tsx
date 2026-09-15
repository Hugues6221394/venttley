import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice } from "@/components/ui/operations";
import { ClipboardCheck } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Queue = {
  label: string;
  count: number | null;
  href: string;
  objective: string;
  critical?: boolean;
};

export default async function QueueControlPage() {
  const db = await createAdminClient();
  const staleMedia = new Date(Date.now() - 15 * 60 * 1000).toISOString();
  const [cases, unassigned, breached, appeals, csam, media, verification, privacy, delivery] = await Promise.all([
    db.from("moderation_cases").select("case_id", { count: "exact", head: true }).neq("status", "resolved"),
    db.from("moderation_cases").select("case_id", { count: "exact", head: true }).neq("status", "resolved").is("assignee_id", null),
    db.from("moderation_cases").select("case_id", { count: "exact", head: true }).neq("status", "resolved").not("sla_breached_at", "is", null),
    db.from("moderation_appeals").select("appeal_id", { count: "exact", head: true }).eq("status", "pending"),
    db.from("csam_incidents").select("incident_id", { count: "exact", head: true }).eq("status", "open"),
    db.from("media_scan_jobs").select("content_id", { count: "exact", head: true }).is("completed_at", null).lt("created_at", staleMedia),
    db.from("verification_requests").select("request_id", { count: "exact", head: true }).in("status", ["pending", "in_review", "info_requested"]),
    db.from("users").select("user_id", { count: "exact", head: true }).not("deletion_requested_at", "is", null),
    db.from("push_delivery_outbox").select("delivery_id", { count: "exact", head: true }).eq("status", "dead"),
  ]);
  const results = [cases, unassigned, breached, appeals, csam, media, verification, privacy, delivery];
  const errors = results.flatMap((result) => result.error ? [result.error.message] : []);
  const queues: Queue[] = [
    { label: "Open moderation cases", count: cases.count, href: "/moderation", objective: "Assign and resolve using severity and persisted SLA." },
    { label: "Unassigned cases", count: unassigned.count, href: "/moderation", objective: "No case should wait without an accountable owner.", critical: true },
    { label: "Breached moderation SLAs", count: breached.count, href: "/slo", objective: "Escalate breached user-safety outcomes immediately.", critical: true },
    { label: "Pending appeals", count: appeals.count, href: "/appeals", objective: "Keep independent review within the published window." },
    { label: "Open CSAM incidents", count: csam.count, href: "/incidents/csam-open", objective: "Restricted child-safety workflow; evidence access is separately logged.", critical: true },
    { label: "Stale media scans", count: media.count, href: "/jobs", objective: "Keep untrusted media quarantined while the scanner is delayed.", critical: true },
    { label: "Verification backlog", count: verification.count, href: "/verification", objective: "Resolve identity-status requests without weakening anonymity." },
    { label: "Deletion requests", count: privacy.count, href: "/privacy", objective: "Track legal deadlines and active retention exceptions.", critical: true },
    { label: "Dead push deliveries", count: delivery.count, href: "/jobs", objective: "Restore safety and account-notice delivery without double-sending." },
  ];
  const knownTotal = queues.reduce((sum, queue) => sum + (queue.count ?? 0), 0);

  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader eyebrow="Operate" title="Queue control" subtitle="One workload view for safety, moderation, privacy, verification, scanning, and delivery. Failed sources remain unknown instead of appearing as zero." />
      {errors.length > 0 && <ErrorPanel title="Queue picture is incomplete" detail={errors.join("\n")} hint="Do not reduce staffing or declare queues clear while a source is unavailable." />}
      <Card>
        <div className="flex flex-wrap items-center gap-3">
          <ClipboardCheck size={20} className={knownTotal > 0 ? "text-warn" : "text-ok"} />
          <p className="text-lg font-extrabold text-burgundy">Known work items</p>
          <span className="text-3xl font-extrabold text-burgundy">{errors.length ? `${knownTotal}+` : knownTotal}</span>
          <Badge tone={errors.length ? "warn" : knownTotal > 0 ? "info" : "ok"}>{errors.length ? "partial" : knownTotal > 0 ? "triage" : "clear"}</Badge>
        </div>
        <p className="mt-2 text-xs text-ink-muted">Counts may overlap when one event creates more than one operational record.</p>
      </Card>
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
        {queues.map((queue) => (
          <Link href={queue.href} key={queue.label} className="surface p-5 transition hover:border-berry/40">
            <div className="flex items-start justify-between gap-3">
              <p className="font-bold text-burgundy">{queue.label}</p>
              <span className="text-2xl font-extrabold text-burgundy">{queue.count ?? "—"}</span>
            </div>
            <p className="mt-2 text-xs leading-relaxed text-ink-muted">{queue.objective}</p>
            <Badge tone={queue.count === null ? "neutral" : (queue.count ?? 0) > 0 ? queue.critical ? "danger" : "warn" : "ok"}>
              {queue.count === null ? "unknown" : (queue.count ?? 0) > 0 ? "work waiting" : "clear"}
            </Badge>
          </Link>
        ))}
      </div>
      <CapabilityNotice title="Workforce scheduling is not inferred from queue counts">
        Shift coverage, reviewer skills, assignments, paging, handoff, and queue
        capacity require a dedicated staffing model. These counts route work but
        do not claim that a trained operator is available.
      </CapabilityNotice>
    </div>
  );
}
