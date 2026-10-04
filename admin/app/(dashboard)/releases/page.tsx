import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { RefreshCw } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type MigrationRow = { version: string; name: string; applied_at: string };
type FlagRow = { flag_key: string; description: string | null; enabled: boolean; rollout_pct: number; environment: string; updated_at: string };
type AlertRow = { alert_id: string; subsystem: string; severity: string; problem: string; created_at: string };

export default async function ReleasesPage() {
  const db = await createAdminClient();
  const [migrationsResult, flagsResult, alertsResult] = await Promise.all([
    db.from("schema_migrations").select("version, name, applied_at").order("version", { ascending: false }).limit(30),
    db.from("feature_flags").select("flag_key, description, enabled, rollout_pct, environment, updated_at").order("updated_at", { ascending: false }).limit(100),
    db.from("platform_alerts").select("alert_id, subsystem, severity, problem, created_at").is("resolved_at", null).order("created_at", { ascending: false }).limit(30),
  ]);
  const results = [migrationsResult, flagsResult, alertsResult];
  const errors = results.flatMap((result) => result.error ? [result.error.message] : []);
  const migrations = (migrationsResult.data ?? []) as MigrationRow[];
  const flags = (flagsResult.data ?? []) as FlagRow[];
  const alerts = (alertsResult.data ?? []) as AlertRow[];
  const rolloutFlags = flags.filter((flag) => flag.enabled && flag.rollout_pct > 0 && flag.rollout_pct < 100);
  const killSwitches = flags.filter((flag) => !flag.enabled || flag.rollout_pct === 0);

  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader
        eyebrow="Insight"
        title="Release readiness"
        subtitle="Database migration evidence, runtime rollout controls, and unresolved platform signals. This is not a deployment system."
        actions={<div className="flex gap-2"><Link href="/flags" className="btn-secondary">Feature flags</Link><Link href="/system" className="btn-secondary">System health</Link></div>}
      />
      <DataWarning caveat title="A migration ledger is not proof of a safe release">
        Venttly does not yet record build provenance, artifact signatures,
        environment promotion, approval gates, smoke-test results, rollback
        rehearsals, or crash-free sessions in one canonical release record.
      </DataWarning>
      {errors.length > 0 && <ErrorPanel title="Release evidence is incomplete" detail={errors.join("\n")} hint="Do not approve a release from partial console data." />}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Recent migrations" value={migrationsResult.error ? null : migrations.length} tone="neutral" />
        <Metric label="Partial rollouts" value={flagsResult.error ? null : rolloutFlags.length} tone={rolloutFlags.length ? "warn" : "ok"} />
        <Metric label="Disabled controls" value={flagsResult.error ? null : killSwitches.length} tone="neutral" />
        <Metric label="Open platform alerts" value={alertsResult.error ? null : alerts.length} tone={alerts.length ? "danger" : "ok"} />
      </div>
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Applied database migrations" hint="Newest 30 ledger records" padded={false}>
          {migrations.length === 0 ? <EmptyState icon={<RefreshCw size={32} />} title="No migration records returned." hint={errors.length ? "The ledger query failed." : "A production database should not be promoted without a migration ledger."} /> : <ul className="divide-y divide-line">{migrations.map((row) => <li key={row.version} className="px-5 py-3"><p className="font-mono text-xs font-bold text-burgundy">{row.version}</p><p className="mt-0.5 text-xs text-ink-muted">{row.name} · {new Date(row.applied_at).toLocaleString()}</p></li>)}</ul>}
        </Card>
        <Card title="Client-version adoption" hint="No scalable aggregate projection exists" padded={false}>
          <EmptyState icon={<RefreshCw size={32} />} title="Client-version adoption is unavailable." hint="The raw event tables are intentionally not scanned or globally sorted on page load. Add an indexed, privacy-safe aggregate by version, platform, and time window." />
        </Card>
      </div>
      <Card title="Runtime rollout posture" hint="All current feature-flag rows; descriptions may be operational metadata" padded={false}>
        {flags.length === 0 ? <p className="px-5 py-10 text-sm italic text-ink-muted">No feature flags returned.</p> : <ul className="divide-y divide-line">{flags.map((flag) => <li key={flag.flag_key} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><span className="font-mono text-xs font-bold text-burgundy">{flag.flag_key}</span><Badge tone={flag.enabled && flag.rollout_pct > 0 ? flag.rollout_pct < 100 ? "warn" : "ok" : "neutral"}>{flag.enabled ? `${flag.rollout_pct}%` : "disabled"}</Badge><Badge>{flag.environment}</Badge></div><p className="mt-1 text-xs text-ink-muted">{flag.description ?? "No operator description"} · updated {new Date(flag.updated_at).toLocaleString()}</p></li>)}</ul>}
      </Card>
      <CapabilityNotice title="Release decisions need a durable promotion workflow">
        Add a release ledger keyed by immutable artifact digest with source commit,
        schema target, environment, approvers, test attestations, risk tier,
        rollout steps, SLO guardrails, rollback command, and final outcome. Deploy
        credentials must stay outside this console.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, tone }: { label: string; value: number | null; tone: "neutral" | "ok" | "warn" | "danger" }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-3xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : tone}>{value === null ? "unknown" : tone === "ok" ? "clear" : tone === "neutral" ? "observed" : "review"}</Badge></div></Card>;
}
