import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { LineChart } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type FeedHealth = { row_count?: number };
type FlagRow = { flag_key: string; description: string | null; enabled: boolean; rollout_pct: number; environment: string; updated_at: string };
type AlertRow = { alert_id: string; subsystem: string; severity: string; problem: string; created_at: string };

const FEED_TERMS = /(feed|discover|recommend|ranking|whisper|trending|hot)/i;

export default async function FeedIntegrityPage() {
  const db = await createAdminClient();
  const [healthResult, flagsResult, alertsResult, mediaPending, crisisTagged] = await Promise.all([
    db.rpc("admin_hot_feed_health"),
    db.from("feature_flags").select("flag_key, description, enabled, rollout_pct, environment, updated_at").order("updated_at", { ascending: false }).limit(100),
    db.from("platform_alerts").select("alert_id, subsystem, severity, problem, created_at").is("resolved_at", null).order("created_at", { ascending: false }).limit(100),
    db.from("posts").select("post_id", { count: "exact", head: true }).eq("media_status", "pending").is("deleted_at", null),
    db.from("posts").select("post_id", { count: "exact", head: true }).not("crisis_level", "is", null).is("deleted_at", null),
  ]);
  const results = [healthResult, flagsResult, alertsResult, mediaPending, crisisTagged];
  const errors = results.flatMap((result) => result.error ? [result.error.message] : []);
  const health = (healthResult.data ?? {}) as FeedHealth;
  const flags = ((flagsResult.data ?? []) as FlagRow[]).filter((row) => FEED_TERMS.test(`${row.flag_key} ${row.description ?? ""}`));
  const alerts = ((alertsResult.data ?? []) as AlertRow[]).filter((row) => FEED_TERMS.test(`${row.subsystem} ${row.problem}`));

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader eyebrow="Operate" title="Feed integrity" subtitle="Operational state around the protected hot-feed cache, rollout controls, media quarantine, and crisis classification. No authored content or user identity is rendered." actions={<div className="flex gap-2"><Link href="/integrity" className="btn-secondary">Platform integrity</Link><Link href="/flags" className="btn-secondary">Feature flags</Link></div>} />
      <DataWarning title="No ranking-fairness or manipulation telemetry exists yet">
        Cache population and feature flags do not prove relevance, diversity,
        freshness, creator fairness, safety, or resistance to coordinated
        engagement. This page must not label a post or account as manipulative.
      </DataWarning>
      {errors.length > 0 && <ErrorPanel title="Feed-integrity evidence is incomplete" detail={errors.join("\n")} hint="Unknown ranking state must not be treated as healthy." />}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Hot-feed cache rows" value={typeof health.row_count === "number" ? health.row_count : null} tone="neutral" />
        <Metric label="Feed controls" value={flagsResult.error ? null : flags.length} tone={flags.some((flag) => flag.enabled && flag.rollout_pct > 0 && flag.rollout_pct < 100) ? "warn" : "neutral"} />
        <Metric label="Media awaiting scan" value={mediaPending.count} tone={(mediaPending.count ?? 0) ? "warn" : "ok"} />
        <Metric label="Crisis-tagged posts" value={crisisTagged.count} tone={(crisisTagged.count ?? 0) ? "warn" : "ok"} />
      </div>
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Feed and discovery controls" hint="Matched from the bounded feature-flag registry" padded={false}>
          {flags.length === 0 ? <EmptyState icon={<LineChart size={32} />} title="No feed controls returned." hint={flagsResult.error ? "The registry query failed." : "A deploy-only ranking change has no gradual rollout or operator kill switch."} /> : <ul className="divide-y divide-line">{flags.map((flag) => <li key={flag.flag_key} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><span className="font-mono text-xs font-bold text-burgundy">{flag.flag_key}</span><Badge tone={flag.enabled && flag.rollout_pct > 0 ? flag.rollout_pct < 100 ? "warn" : "ok" : "neutral"}>{flag.enabled ? `${flag.rollout_pct}%` : "disabled"}</Badge><Badge>{flag.environment}</Badge></div><p className="mt-1 text-xs text-ink-muted">{flag.description ?? "No operator description"}</p></li>)}</ul>}
        </Card>
        <Card title="Unresolved feed signals" hint="Matched from the newest 100 open platform alerts" padded={false}>
          {alerts.length === 0 ? <EmptyState icon={<LineChart size={32} />} title="No feed-specific alert returned." hint={alertsResult.error ? "Alert telemetry is unavailable." : "This bounded registry does not include external observability or product-quality alarms."} /> : <ul className="divide-y divide-line">{alerts.map((alert) => <li key={alert.alert_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Badge tone={alert.severity === "critical" ? "danger" : "warn"}>{alert.severity}</Badge><span className="font-bold text-burgundy">{alert.subsystem}</span></div><p className="mt-1 text-xs text-ink-muted">{alert.problem.slice(0, 180)}</p><p className="mt-1 text-[11px] text-ink-muted">{new Date(alert.created_at).toLocaleString()}</p></li>)}</ul>}
        </Card>
      </div>
      <CapabilityNotice title="Ranking integrity needs privacy-safe aggregate instrumentation">
        Add versioned ranking policies, exposure distributions, freshness and
        diversity measures, repeat-impression rates, safety prevalence,
        suspected coordinated-engagement cohorts, experiment assignment,
        counterfactual evaluation, SLOs, and audited rollback. Use pseudonymous
        aggregates with bounded retention—not a raw user surveillance graph.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, tone }: { label: string; value: number | null; tone: "neutral" | "ok" | "warn" }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-3xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : tone}>{value === null ? "unknown" : tone === "ok" ? "clear" : tone === "warn" ? "review" : "observed"}</Badge></div></Card>;
}
