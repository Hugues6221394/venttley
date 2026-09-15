import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { Users2 } from "@/components/ui/icons";

export const dynamic = "force-dynamic";
const LIMIT = 50;

type TribeRow = {
  tribe_id: string;
  name: string;
  slug: string;
  member_count: number;
  keeper_id: string | null;
  is_private: boolean;
  is_suspended: boolean;
  is_active: boolean;
  lifecycle_status: string;
  deletion_purge_at: string | null;
  updated_at: string;
};
type JoinRequest = { request_id: string; tribe_id: string; status: string; created_at: string };

export default async function TribeGovernancePage() {
  const db = await createAdminClient();
  const columns = "tribe_id, name, slug, member_count, keeper_id, is_private, is_suspended, is_active, lifecycle_status, deletion_purge_at, updated_at";
  const [deletionsResult, suspendedResult, keeperlessResult, requestsResult] = await Promise.all([
    db.from("tribes").select(columns).eq("lifecycle_status", "pending_deletion").order("deletion_purge_at", { ascending: true }).limit(LIMIT),
    db.from("tribes").select(columns).eq("is_suspended", true).order("updated_at", { ascending: false }).limit(LIMIT),
    db.from("tribes").select(columns).is("keeper_id", null).eq("is_active", true).order("updated_at", { ascending: false }).limit(LIMIT),
    db.from("tribe_join_requests").select("request_id, tribe_id, status, created_at").eq("status", "pending").order("created_at", { ascending: true }).limit(LIMIT),
  ]);
  const results = [deletionsResult, suspendedResult, keeperlessResult, requestsResult];
  const errors = results.flatMap((result) => result.error ? [result.error.message] : []);
  const deletionRows = (deletionsResult.data ?? []) as TribeRow[];
  const suspendedRows = (suspendedResult.data ?? []) as TribeRow[];
  const keeperlessRows = (keeperlessResult.data ?? []) as TribeRow[];
  const requests = (requestsResult.data ?? []) as JoinRequest[];
  const candidates = new Map<string, { tribe: TribeRow; reasons: string[] }>();
  for (const [rows, reason] of [[deletionRows, "pending deletion"], [suspendedRows, "suspended"], [keeperlessRows, "active without keeper"]] as const) {
    for (const tribe of rows) {
      const existing = candidates.get(tribe.tribe_id);
      if (existing) existing.reasons.push(reason);
      else candidates.set(tribe.tribe_id, { tribe, reasons: [reason] });
    }
  }

  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader eyebrow="Operate" title="Tribe governance" subtitle="Bounded lifecycle, suspension, stewardship, and join-request queues. Member notes, message bodies, ban reasons, and private community content are omitted." actions={<Link href="/tribes" className="btn-secondary">Tribe directory</Link>} />
      <DataWarning title="Returned rows are bounded samples, not platform totals">
        Each source stops at {LIMIT} rows to keep the page predictable. A value
        of {LIMIT}+ means the backend must provide an indexed aggregate before
        an operator can know the full backlog.
      </DataWarning>
      {errors.length > 0 && <ErrorPanel title="Tribe-governance evidence is incomplete" detail={errors.join("\n")} hint="Unavailable sources are not treated as empty queues." />}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Pending deletion" value={bounded(deletionRows.length, !!deletionsResult.error)} tone={deletionRows.length ? "danger" : "ok"} />
        <Metric label="Suspended" value={bounded(suspendedRows.length, !!suspendedResult.error)} tone={suspendedRows.length ? "warn" : "ok"} />
        <Metric label="Active without keeper" value={bounded(keeperlessRows.length, !!keeperlessResult.error)} tone={keeperlessRows.length ? "warn" : "ok"} />
        <Metric label="Pending join requests" value={bounded(requests.length, !!requestsResult.error)} tone={requests.length ? "info" : "ok"} />
      </div>
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Governance candidates" hint="Union of lifecycle, suspension, and stewardship queues" padded={false}>
          {candidates.size === 0 ? <EmptyState icon={<Users2 size={32} />} title="No governance candidates returned." hint={errors.length ? "One or more sources are unavailable." : "This does not measure moderator quality, rule enforcement, or community health."} /> : <ul className="divide-y divide-line">{[...candidates.values()].map(({ tribe, reasons }) => <li key={tribe.tribe_id} className="px-5 py-4"><div className="flex flex-wrap items-center gap-2"><Link href={`/tribes/${tribe.tribe_id}`} className="font-bold text-burgundy hover:text-berry">{tribe.name}</Link><span className="text-xs text-ink-muted">/{tribe.slug}</span>{reasons.map((reason) => <Badge key={reason} tone={reason === "pending deletion" ? "danger" : "warn"}>{reason}</Badge>)}</div><p className="mt-1 text-xs text-ink-muted">{tribe.member_count.toLocaleString()} members · {tribe.is_private ? "private" : "public"} · updated {new Date(tribe.updated_at).toLocaleString()}{tribe.deletion_purge_at ? ` · purge due ${new Date(tribe.deletion_purge_at).toLocaleString()}` : ""}</p></li>)}</ul>}
        </Card>
        <Card title="Oldest pending join requests" hint="No applicant identity or note rendered" padded={false}>
          {requests.length === 0 ? <EmptyState icon={<Users2 size={32} />} title="No pending join requests returned." hint={requestsResult.error ? "The queue query failed." : "Private Tribe demand is currently clear in this bounded view."} /> : <ul className="divide-y divide-line">{requests.map((request) => <li key={request.request_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Badge tone="info">pending</Badge><Link href={`/tribes/${request.tribe_id}`} className="text-xs font-bold text-berry hover:underline">Open Tribe</Link></div><p className="mt-1 text-[11px] text-ink-muted">waiting since {new Date(request.created_at).toLocaleString()}</p></li>)}</ul>}
        </Card>
      </div>
      <CapabilityNotice title="Community governance needs explicit accountability contracts">
        Add keeper tenure and attestation history, moderator rosters, rule-version
        adoption, response-time SLOs, warning and ban appeals, risk-weighted
        escalations, inactive-keeper transfer, member-safety aggregates, deletion
        approvals, and audited rollback. Bulk community actions must be idempotent
        and separately authorized.
      </CapabilityNotice>
    </div>
  );
}

function bounded(length: number, failed: boolean): string | null { return failed ? null : length === LIMIT ? `${LIMIT}+` : String(length); }
function Metric({ label, value, tone }: { label: string; value: string | null; tone: "ok" | "warn" | "danger" | "info" }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-3xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : tone}>{value === null ? "unknown" : tone === "ok" ? "clear" : "review"}</Badge></div></Card>;
}
