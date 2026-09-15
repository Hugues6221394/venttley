import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { BookOpenCheck } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type PolicyRow = {
  kind: string;
  version: string;
  title: string;
  summary: string | null;
  body_url: string | null;
  effective_at: string;
  material: boolean;
  retired_at: string | null;
  created_at: string;
};

export default async function PolicyVersionsPage() {
  const db = await createAdminClient();
  const result = await db.from("policy_documents").select("kind, version, title, summary, body_url, effective_at, material, retired_at, created_at").order("kind").order("effective_at", { ascending: false }).limit(200);
  const rows = (result.data ?? []) as PolicyRow[];
  const now = Date.now();
  const currentByKind = new Map<string, string>();
  for (const row of rows) {
    if (!row.retired_at && new Date(row.effective_at).getTime() <= now && !currentByKind.has(row.kind)) currentByKind.set(row.kind, row.version);
  }
  const currentCount = currentByKind.size;
  const scheduled = rows.filter((row) => !row.retired_at && new Date(row.effective_at).getTime() > now).length;
  const retired = rows.filter((row) => !!row.retired_at).length;
  const material = rows.filter((row) => row.material).length;

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader eyebrow="Control" title="Policy versions" subtitle="Effective, scheduled, and retired policy records. Body content is not rendered in the console, and no document URL is trusted as an operator-safe link." actions={<Link href="/moderation/policies" className="btn-secondary">Moderation policy center</Link>} />
      <DataWarning title="Acceptance coverage is intentionally absent">
        Calculating acceptance separately for every version would create an N+1
        workload and misleading denominators. A database-owned aggregate must
        define eligible users, superseded versions, grace periods, and consent
        revocation before coverage can be displayed safely.
      </DataWarning>
      {result.error && <ErrorPanel title="Policy ledger is unavailable" detail={result.error.message} />}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Current kinds" value={result.error ? null : currentCount} tone="ok" />
        <Metric label="Scheduled" value={result.error ? null : scheduled} tone={scheduled ? "info" : "neutral"} />
        <Metric label="Retired versions" value={result.error ? null : retired} tone="neutral" />
        <Metric label="Material versions" value={result.error ? null : material} tone={material ? "warn" : "neutral"} />
      </div>
      <Card title="Version ledger" hint={`Bounded to ${rows.length} records`} padded={false}>
        {rows.length === 0 ? <EmptyState icon={<BookOpenCheck size={32} />} title="No policy versions returned." hint={result.error ? "The ledger query failed." : "Publishing must remain blocked until required policy kinds exist."} /> : <ul className="divide-y divide-line">{rows.map((row) => {
          const state = row.retired_at ? "retired" : new Date(row.effective_at).getTime() > now ? "scheduled" : currentByKind.get(row.kind) === row.version ? "current" : "superseded";
          return <li key={`${row.kind}-${row.version}`} className="px-5 py-4"><div className="flex flex-wrap items-center gap-2"><span className="font-bold text-burgundy">{row.title}</span><Badge>{row.kind.replaceAll("_", " ")}</Badge><Badge tone={state === "current" ? "ok" : state === "scheduled" ? "info" : "neutral"}>{state}</Badge>{row.material && <Badge tone="warn">material</Badge>}</div><p className="mt-1 text-xs text-ink-muted">Version {row.version} · effective {new Date(row.effective_at).toLocaleString()}{row.retired_at ? ` · retired ${new Date(row.retired_at).toLocaleString()}` : ""}</p>{row.summary && <p className="mt-2 text-xs leading-relaxed text-ink-muted">{row.summary.slice(0, 280)}</p>}<p className="mt-1 text-[11px] text-ink-muted">{row.body_url ? "An external body reference is recorded but not linked from this privileged console." : "Canonical body stored in the policy record."}</p></li>;
        })}</ul>}
      </Card>
      <CapabilityNotice title="Publishing policy needs approval, integrity, and consent gates">
        Add draft/review/publish transitions, two-person approval for material
        changes, immutable body hashes, locale coverage, legal owner, effective
        windows, rollback rules, aggregate acceptance projections, grace periods,
        and actor-bound audit events. Direct table editing is not a release process.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, tone }: { label: string; value: number | null; tone: "neutral" | "ok" | "warn" | "info" }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-3xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : tone}>{value === null ? "unknown" : tone === "ok" ? "effective" : tone === "warn" ? "review" : "observed"}</Badge></div></Card>;
}
