import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice } from "@/components/ui/operations";
import { BriefcaseBusiness, ExternalLink } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type PushFailure = { delivery_id: string; event_kind: string; attempts: number; last_error_code: string | null; created_at: string };
type EmailFailure = { outbox_id: string; template: string; attempts: number; last_error: string | null; created_at: string };
type MediaJob = { kind: string; content_id: string; attempts: number; lease_expires_at: string | null; created_at: string };

export default async function JobsPage() {
  const db = await createAdminClient();
  const [pushQueued, pushDead, emailQueued, emailFailed, mediaPending, pushRows, emailRows, mediaRows] = await Promise.all([
    db.from("push_delivery_outbox").select("delivery_id", { count: "exact", head: true }).in("status", ["queued", "processing"]),
    db.from("push_delivery_outbox").select("delivery_id", { count: "exact", head: true }).eq("status", "dead"),
    db.from("email_outbox").select("outbox_id", { count: "exact", head: true }).in("status", ["queued", "sending"]),
    db.from("email_outbox").select("outbox_id", { count: "exact", head: true }).eq("status", "failed"),
    db.from("media_scan_jobs").select("content_id", { count: "exact", head: true }).is("completed_at", null),
    db.from("push_delivery_outbox").select("delivery_id, event_kind, attempts, last_error_code, created_at").eq("status", "dead").order("created_at", { ascending: false }).limit(30),
    db.from("email_outbox").select("outbox_id, template, attempts, last_error, created_at").eq("status", "failed").order("created_at", { ascending: false }).limit(30),
    db.from("media_scan_jobs").select("kind, content_id, attempts, lease_expires_at, created_at").is("completed_at", null).order("created_at", { ascending: true }).limit(30),
  ]);
  const results = [pushQueued, pushDead, emailQueued, emailFailed, mediaPending, pushRows, emailRows, mediaRows];
  const errors = results.flatMap((result) => result.error ? [result.error.message] : []);
  const failures = (pushRows.data?.length ?? 0) + (emailRows.data?.length ?? 0) + (mediaRows.data?.length ?? 0);

  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader eyebrow="Insight" title="Jobs & delivery" subtitle="Outcome-oriented visibility for push, email, and media-scan work. Recipient addresses, message bodies, tokens, and notification payloads are never rendered here." actions={<Link href="/system" className="btn-secondary">System health <ExternalLink size={12} /></Link>} />
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
        <Metric label="Push waiting" value={pushQueued.count} warn={(pushQueued.count ?? 0) > 0} />
        <Metric label="Push dead" value={pushDead.count} danger={(pushDead.count ?? 0) > 0} />
        <Metric label="Email waiting" value={emailQueued.count} warn={(emailQueued.count ?? 0) > 0} />
        <Metric label="Email failed" value={emailFailed.count} danger={(emailFailed.count ?? 0) > 0} />
        <Metric label="Media pending" value={mediaPending.count} warn={(mediaPending.count ?? 0) > 0} />
      </div>
      {errors.length > 0 && <ErrorPanel title="Job health is incomplete" detail={errors.join("\n")} hint="Unknown is not treated as zero; investigate the failing source before declaring delivery healthy." />}
      {errors.length === 0 && failures === 0 ? (
        <Card><EmptyState icon={<BriefcaseBusiness size={34} />} title="No failed or pending jobs are visible." hint="This is a point-in-time queue state, not proof that downstream providers delivered successfully." /></Card>
      ) : (
        <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
          <JobList title="Dead push deliveries" rows={(pushRows.data ?? []) as PushFailure[]} render={(row) => <><p className="font-semibold text-burgundy">{row.event_kind}</p><p className="text-xs text-ink-muted">{row.attempts} attempts · {row.last_error_code ?? "no error code"}</p></>} id={(row) => row.delivery_id} time={(row) => row.created_at} />
          <JobList title="Failed email deliveries" rows={(emailRows.data ?? []) as EmailFailure[]} render={(row) => <><p className="font-semibold text-burgundy">{row.template}</p><p className="text-xs text-ink-muted">{row.attempts} attempts · {row.last_error ? row.last_error.slice(0, 140) : "no provider error"}</p></>} id={(row) => row.outbox_id} time={(row) => row.created_at} />
          <JobList title="Pending media scans" rows={(mediaRows.data ?? []) as MediaJob[]} render={(row) => <><p className="font-semibold text-burgundy">{row.kind}</p><p className="text-xs text-ink-muted">{row.attempts} attempts · content {row.content_id.slice(0, 8)}…</p></>} id={(row) => `${row.kind}-${row.content_id}`} time={(row) => row.created_at} />
        </div>
      )}
      <CapabilityNotice title="Replay controls require idempotent worker contracts">
        This page is read-only until push, email, and media workers expose narrow,
        audited replay RPCs that cannot double-send. Cron visibility also needs a
        server-side projection of schedule freshness and downstream outcomes;
        a successful pg_net enqueue alone is not delivery success.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, warn = false, danger = false }: { label: string; value: number | null; warn?: boolean; danger?: boolean }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-2xl font-extrabold text-burgundy">{value ?? "—"}</p>{danger ? <Badge tone="danger">action</Badge> : warn ? <Badge tone="warn">watch</Badge> : value !== null ? <Badge tone="ok">clear</Badge> : <Badge>unknown</Badge>}</div></Card>;
}

function JobList<T>({ title, rows, render, id, time }: { title: string; rows: T[]; render: (row: T) => React.ReactNode; id: (row: T) => string; time: (row: T) => string }) {
  return <Card title={title} hint={`Latest ${rows.length}`} padded={false}>{rows.length === 0 ? <p className="px-5 py-10 text-sm italic text-ink-muted">Nothing in this state.</p> : <ul className="divide-y divide-line">{rows.map((row) => <li key={id(row)} className="px-5 py-3">{render(row)}<p className="mt-1 text-[11px] text-ink-muted">{new Date(time(row)).toLocaleString()}</p></li>)}</ul>}</Card>;
}
