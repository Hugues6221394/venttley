import { notFound } from "next/navigation";
import Link from "next/link";
import { getOperationalRole } from "@/lib/governance";
import { broadcastApprovalCursor } from "@/lib/broadcast-approval-model";
import { BroadcastApprovalRegister } from "@/components/workflows/broadcast-approval-register";
import { BroadcastComposer, WithdrawBroadcast, type BroadcastTribe } from "@/components/broadcast-composer";
import { DataWarning } from "@/components/ui/operations";
import { createSsrClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Megaphone, AlertTriangle, Heart, Info } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Urgency = "info" | "warning" | "critical" | "crisis";
type DeliveryState = "waiting" | "delivering" | "delivered" | "expired" | "withdrawing" | "withdrawn" | "predates_delivery";
type Row = {
  broadcast_id: string;
  title: string;
  body: string;
  urgency: Urgency;
  audience: { scope: string; value?: string } | null;
  scheduled_for: string | null;
  sent_at: string | null;
  expires_at: string | null;
  is_active: boolean;
  created_at: string;
  delivered_count: number;
  delivery_state: DeliveryState;
  audience_size: number | null;
  withdrawn: number;
  tribe_name: string | null;
  sent_by_name: string;
};

const STATE: Record<DeliveryState, { label: string; tone: "ok" | "warn" | "danger" | "info" | "neutral" }> = {
  waiting: { label: "scheduled", tone: "info" },
  delivering: { label: "delivering", tone: "warn" },
  delivered: { label: "delivered", tone: "ok" },
  expired: { label: "expired before finishing", tone: "neutral" },
  withdrawing: { label: "withdrawing", tone: "warn" },
  withdrawn: { label: "withdrawn", tone: "neutral" },
  predates_delivery: { label: "never delivered", tone: "neutral" },
};

export default async function BroadcastsPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const role = await getOperationalRole();
  if (role !== "super_admin" && role !== "admin") notFound();
  const params = await searchParams;
  if (process.env.ADMIN_BROADCAST_APPROVALS_UI === "true") {
    const cursor = broadcastApprovalCursor(params);
    if (!cursor) return <div><DataWarning title="Invalid queue cursor">Restart the broadcast queue.</DataWarning><Link href="/broadcasts" className="btn-secondary">Reset filters</Link></div>;
    return <BroadcastApprovalRegister cursor={cursor} superAdmin={role === "super_admin"} />;
  }
  if (params.source !== undefined) return <DataWarning title="Approval interface unavailable">This request requires the separately enabled approval interface. No unrelated record is shown.</DataWarning>;

  const db = await createSsrClient();
  const [register, audience, tribes] = await Promise.all([
    db.rpc("admin_broadcast_register", { p_limit: 100 }),
    db.rpc("admin_broadcast_audience", {}),
    db.rpc("admin_broadcast_tribes", { p_query: "" }),
  ]);
  if (register.error) return <div className="flex flex-col gap-6">
    <PageHeader eyebrow="Operate" title="Broadcasts" subtitle="Announcements from the Venttly team" />
    <DataWarning title="Broadcast data unavailable">Delivery figures are unknown, not zero. Reload to retry.</DataWarning>
    <a href="/broadcasts" className="btn-secondary">Reload broadcasts</a>
  </div>;

  const rows = (register.data ?? []) as Row[];
  const live = rows.filter(r => ["delivering", "delivered", "withdrawing"].includes(r.delivery_state) && r.is_active);
  const scheduled = rows.filter(r => r.delivery_state === "waiting" && r.is_active);
  const past = rows.filter(r => !live.includes(r) && !scheduled.includes(r));
  const everyone = audience.error ? null : Number((audience.data as { members?: number } | null)?.members ?? 0);

  return (
    <div className="flex flex-col gap-6 max-w-[1100px]">
      <PageHeader eyebrow="Operate" title="Broadcasts"
        subtitle="Announcements from the Venttly team, delivered to members as a notification with the usual generic push." />
      <Card title="New broadcast" padded>
        <BroadcastComposer everyone={everyone} tribes={tribes.error ? [] : (tribes.data ?? []) as BroadcastTribe[]} />
      </Card>
      <Section title="Live" rows={live} empty="Nothing is live. Publish one above; members get it within minutes." />
      <Section title="Scheduled" rows={scheduled} />
      <Section title="Past" rows={past} />
    </div>
  );
}

function Section({ title, rows, empty }: { title: string; rows: Row[]; empty?: string }) {
  if (rows.length === 0) {
    if (!empty) return null;
    return <Card title={title} padded><EmptyState icon={<Megaphone size={28} />} title={empty} /></Card>;
  }
  return (
    <Card title={title} padded={false}>
      <ul className="divide-y divide-line">
        {rows.map(r => {
          const state = STATE[r.delivery_state] ?? STATE.predates_delivery;
          const withdrawable = r.is_active && r.delivery_state !== "predates_delivery";
          return (
            <li key={r.broadcast_id} className="px-5 py-4">
              <div className="flex items-start gap-3">
                <UrgencyIcon urgency={r.urgency} />
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <p className="font-extrabold text-burgundy">{r.title}</p>
                    <Badge tone={urgencyTone(r.urgency)}>{r.urgency}</Badge>
                    <Badge tone="neutral">{audienceLabel(r)}</Badge>
                    <Badge tone={state.tone}>{state.label}</Badge>
                  </div>
                  <p className="text-sm text-burgundy/90 mt-1 whitespace-pre-wrap">{r.body}</p>
                  <p className="text-[11px] text-ink-muted mt-2">
                    {r.sent_at ? `Sent ${new Date(r.sent_at).toLocaleString()}` : r.scheduled_for ? `Sends ${new Date(r.scheduled_for).toLocaleString()}` : `Created ${new Date(r.created_at).toLocaleString()}`}
                    {" by "}{r.sent_by_name}
                    {r.expires_at && ` · expires ${new Date(r.expires_at).toLocaleString()}`}
                    {" · "}{progress(r)}
                  </p>
                </div>
                {withdrawable && <WithdrawBroadcast broadcastId={r.broadcast_id} />}
              </div>
            </li>
          );
        })}
      </ul>
    </Card>
  );
}

function progress(r: Row): string {
  if (r.delivery_state === "predates_delivery") return "published before delivery existed; no member received it";
  if (r.delivery_state === "waiting") return "not sent yet";
  const reached = `${r.delivered_count.toLocaleString()}${r.audience_size !== null ? ` of ${r.audience_size.toLocaleString()}` : ""} members reached`;
  if (r.delivery_state === "withdrawing" || r.delivery_state === "withdrawn") return `${reached}, ${r.withdrawn.toLocaleString()} removed`;
  return reached;
}

function audienceLabel(r: Row): string {
  if (!r.audience || r.audience.scope === "all") return "everyone";
  if (r.audience.scope === "tribe") return `tribe: ${r.tribe_name ?? "removed tribe"}`;
  return r.audience.scope;
}

function urgencyTone(u: Urgency): "warn" | "danger" | "info" | "crisis" {
  return u === "info" ? "info" : u === "warning" ? "warn" : u === "critical" ? "danger" : "crisis";
}

function UrgencyIcon({ urgency }: { urgency: Urgency }) {
  const cls = urgency === "crisis" || urgency === "critical" ? "text-danger" : urgency === "warning" ? "text-warn" : "text-info";
  if (urgency === "crisis") return <Heart size={18} className={cls} fill="currentColor" />;
  if (urgency === "critical" || urgency === "warning") return <AlertTriangle size={18} className={cls} />;
  return <Info size={18} className={cls} />;
}
