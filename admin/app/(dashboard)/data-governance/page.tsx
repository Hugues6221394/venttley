import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { Database } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type PolicyRow = { kind: string; version: string; title: string; effective_at: string; material: boolean };

const DATA_SURFACES = [
  { name: "Identity and access", store: "Supabase Auth + public.users", className: "restricted", boundary: "Contact and recovery fields remain outside public profile DTOs." },
  { name: "Vents and conversations", store: "PostgreSQL", className: "highly sensitive", boundary: "Authored bodies require RLS, moderation-purpose access, and minimal rendering." },
  { name: "Uploaded media", store: "Supabase Storage + metadata", className: "sensitive", boundary: "Object access and scan state must stay bound to the canonical owner/content row." },
  { name: "Push delivery", store: "FCM via server outbox", className: "restricted", boundary: "Current worker emits generic copy; device tokens and authored previews stay out of the console." },
  { name: "Space summaries", store: "PostgreSQL + local summarizer", className: "aggregate", boundary: "Current worker consumes aggregate mood counts and makes no third-party AI request." },
  { name: "Music references", store: "PostgreSQL + authorized provider URLs", className: "public metadata", boundary: "Catalog references are not proof of licensing territory or term validity." },
] as const;

export default async function DataGovernancePage() {
  const db = await createAdminClient();
  const now = new Date().toISOString();
  const policiesResult = await db
    .from("policy_documents")
    .select("kind, version, title, effective_at, material")
    .is("retired_at", null)
    .lte("effective_at", now)
    .order("kind")
    .order("effective_at", { ascending: false })
    .limit(100);
  const current = new Map<string, PolicyRow>();
  for (const row of (policiesResult.data ?? []) as PolicyRow[]) {
    if (!current.has(row.kind)) current.set(row.kind, row);
  }

  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader
        eyebrow="Manage"
        title="Data governance"
        subtitle="A minimum-data operational map for Venttly's sensitive stores and currently effective policy records. It deliberately contains no user-level personal data."
        actions={<div className="flex gap-2"><Link href="/privacy" className="btn-secondary">Privacy requests</Link><Link href="/policy/versions" className="btn-secondary">Policy versions</Link></div>}
      />
      <DataWarning caveat title="This is not yet a legal record of processing activities">
        The repository can show intended technical boundaries, but it cannot
        prove production processor contracts, data residency, transfer basis,
        retention execution, subprocessor changes, or regional consent scope.
      </DataWarning>
      {policiesResult.error && <ErrorPanel title="Current policy evidence is unavailable" detail={policiesResult.error.message} />}
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        {DATA_SURFACES.map((surface) => (
          <Card key={surface.name}>
            <div className="flex items-start gap-3">
              <Database size={18} className="mt-0.5 shrink-0 text-berry" />
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2"><p className="font-bold text-burgundy">{surface.name}</p><Badge tone={surface.className === "highly sensitive" ? "danger" : surface.className === "restricted" ? "warn" : "info"}>{surface.className}</Badge></div>
                <p className="mt-1 font-mono text-[11px] text-ink-muted">{surface.store}</p>
                <p className="mt-2 text-xs leading-relaxed text-ink-muted">{surface.boundary}</p>
              </div>
            </div>
          </Card>
        ))}
      </div>
      <Card title="Effective policy records" hint="Latest non-retired effective version per policy kind" padded={false}>
        {current.size === 0 ? <p className="px-5 py-10 text-sm italic text-ink-muted">No effective policy documents returned.</p> : <ul className="divide-y divide-line">{[...current.values()].map((row) => <li key={`${row.kind}-${row.version}`} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><span className="font-bold text-burgundy">{row.title}</span><Badge>{row.kind.replaceAll("_", " ")}</Badge><Badge tone={row.material ? "warn" : "neutral"}>{row.material ? "material" : "non-material"}</Badge></div><p className="mt-1 text-xs text-ink-muted">Version {row.version} · effective {new Date(row.effective_at).toLocaleString()}</p></li>)}</ul>}
      </Card>
      <CapabilityNotice title="Processor, retention, and lineage registries remain missing">
        The backend phase needs owner-approved data classes, purpose, legal basis,
        regions, processor/subprocessor, contract dates, transfer safeguards,
        retention and purge evidence, schema lineage, access roles, incident links,
        and immutable change history. Secrets and user content must never be stored
        in that registry.
      </CapabilityNotice>
    </div>
  );
}
