import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { Megaphone } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type WaitingPush = { delivery_id: string; event_kind: string; status: string; attempts: number; created_at: string };
type WaitingEmail = { outbox_id: string; template: string; status: string; attempts: number; created_at: string };
type BroadcastRow = { broadcast_id: string; title: string; urgency: string; delivered_count: number; dismissed_count: number; is_active: boolean; scheduled_for: string | null; sent_at: string | null; created_at: string };

export default async function DeliveryPage() {
  const db = await createAdminClient();
  const dayAgo = new Date(Date.now() - 86_400_000).toISOString();
  const [pushSent, pushDead, emailSent, emailFailed, pushWaiting, emailWaiting, broadcastsResult] = await Promise.all([
    db.from("push_delivery_outbox").select("delivery_id", { count: "exact", head: true }).eq("status", "sent").gte("sent_at", dayAgo),
    db.from("push_delivery_outbox").select("delivery_id", { count: "exact", head: true }).eq("status", "dead").gte("created_at", dayAgo),
    db.from("email_outbox").select("outbox_id", { count: "exact", head: true }).eq("status", "sent").gte("sent_at", dayAgo),
    db.from("email_outbox").select("outbox_id", { count: "exact", head: true }).eq("status", "failed").gte("created_at", dayAgo),
    db.from("push_delivery_outbox").select("delivery_id, event_kind, status, attempts, created_at").in("status", ["queued", "processing"]).order("created_at", { ascending: true }).limit(30),
    db.from("email_outbox").select("outbox_id, template, status, attempts, created_at").in("status", ["queued", "sending"]).order("created_at", { ascending: true }).limit(30),
    db.from("broadcasts").select("broadcast_id, title, urgency, delivered_count, dismissed_count, is_active, scheduled_for, sent_at, created_at").order("created_at", { ascending: false }).limit(25),
  ]);
  const results = [pushSent, pushDead, emailSent, emailFailed, pushWaiting, emailWaiting, broadcastsResult];
  const errors = results.flatMap((result) => result.error ? [result.error.message] : []);
  const waitingPush = (pushWaiting.data ?? []) as WaitingPush[];
  const waitingEmail = (emailWaiting.data ?? []) as WaitingEmail[];
  const broadcasts = (broadcastsResult.data ?? []) as BroadcastRow[];
  const pushTerminal = (pushSent.count ?? 0) + (pushDead.count ?? 0);
  const emailTerminal = (emailSent.count ?? 0) + (emailFailed.count ?? 0);
  const pushRate = pushTerminal ? Math.round(((pushSent.count ?? 0) / pushTerminal) * 100) : null;
  const emailRate = emailTerminal ? Math.round(((emailSent.count ?? 0) / emailTerminal) * 100) : null;

  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader
        eyebrow="Operate"
        title="Delivery operations"
        subtitle="Queue acceptance and application-level outcomes for push, email, and broadcasts. Recipient addresses, push tokens, authored content, and payloads are never rendered."
        actions={<div className="flex gap-2"><Link href="/jobs" className="btn-secondary">Failed jobs</Link><Link href="/broadcasts" className="btn-secondary">Broadcasts</Link></div>}
      />
      <DataWarning caveat title="Accepted by a provider is not received by a person">
        These rates measure Venttly&apos;s terminal queue state. They do not prove
        device display, inbox placement, opening, reading, or downstream provider
        health.
      </DataWarning>
      {errors.length > 0 && <ErrorPanel title="Delivery outcomes are incomplete" detail={errors.join("\n")} hint="A failed source is shown as unknown rather than zero." />}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Push terminal · 24h" value={pushTerminal} suffix={pushRate === null ? "no outcomes" : `${pushRate}% sent`} tone={(pushDead.count ?? 0) ? "warn" : "ok"} unknown={!!pushSent.error || !!pushDead.error} />
        <Metric label="Push waiting sample" value={waitingPush.length} suffix="oldest first" tone={waitingPush.length ? "warn" : "ok"} unknown={!!pushWaiting.error} />
        <Metric label="Email terminal · 24h" value={emailTerminal} suffix={emailRate === null ? "no outcomes" : `${emailRate}% sent`} tone={(emailFailed.count ?? 0) ? "warn" : "ok"} unknown={!!emailSent.error || !!emailFailed.error} />
        <Metric label="Email waiting sample" value={waitingEmail.length} suffix="oldest first" tone={waitingEmail.length ? "warn" : "ok"} unknown={!!emailWaiting.error} />
      </div>
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <WaitingList title="Oldest push work" rows={waitingPush.map((row) => ({ id: row.delivery_id, kind: row.event_kind, status: row.status, attempts: row.attempts, created_at: row.created_at }))} />
        <WaitingList title="Oldest email work" rows={waitingEmail.map((row) => ({ id: row.outbox_id, kind: row.template, status: row.status, attempts: row.attempts, created_at: row.created_at }))} />
      </div>
      <Card title="Recent broadcasts" hint="Delivery counters only; audience definition and body omitted" padded={false}>
        {broadcasts.length === 0 ? <EmptyState icon={<Megaphone size={32} />} title="No broadcasts returned." hint={errors.length ? "The source may be unavailable." : "No broadcast has been created."} /> : (
          <ul className="divide-y divide-line">{broadcasts.map((row) => <li key={row.broadcast_id} className="px-5 py-4"><div className="flex flex-wrap items-center gap-2"><span className="font-bold text-burgundy">{row.title}</span><Badge tone={row.urgency === "critical" ? "danger" : "neutral"}>{row.urgency}</Badge>{row.is_active && <Badge tone="info">active</Badge>}</div><p className="mt-1 text-xs text-ink-muted">{row.delivered_count.toLocaleString()} application deliveries · {row.dismissed_count.toLocaleString()} dismissed · {row.sent_at ? `sent ${new Date(row.sent_at).toLocaleString()}` : row.scheduled_for ? `scheduled ${new Date(row.scheduled_for).toLocaleString()}` : "not sent"}</p></li>)}</ul>
        )}
      </Card>
      <CapabilityNotice title="Safe replay and provider receipts need backend contracts">
        The backend phase must add idempotent per-delivery replay, dead-letter
        reason classes, queue-age SLO projections, provider receipt ingestion,
        sampled tracing, pause/kill controls, and audited worker state changes.
        This page intentionally cannot bulk resend notifications.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, suffix, tone, unknown }: { label: string; value: number; suffix: string; tone: "ok" | "warn"; unknown: boolean }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-3xl font-extrabold text-burgundy">{unknown ? "—" : value}</p><Badge tone={unknown ? "neutral" : tone}>{unknown ? "unknown" : suffix}</Badge></div></Card>;
}

function WaitingList({ title, rows }: { title: string; rows: { id: string; kind: string; status: string; attempts: number; created_at: string }[] }) {
  return <Card title={title} hint={`Bounded to ${rows.length} records`} padded={false}>{rows.length === 0 ? <p className="px-5 py-10 text-sm italic text-ink-muted">No waiting work returned.</p> : <ul className="divide-y divide-line">{rows.map((row) => <li key={row.id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><span className="font-semibold text-burgundy">{row.kind}</span><Badge tone="warn">{row.status}</Badge><Badge>{row.attempts} attempts</Badge></div><p className="mt-1 text-[11px] text-ink-muted">queued {new Date(row.created_at).toLocaleString()}</p></li>)}</ul>}</Card>;
}
