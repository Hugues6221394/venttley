import { ImpactNav } from "@/components/impact-nav";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { DataWarning } from "@/components/ui/operations";
import { getImpactMethodology } from "@/lib/impact";

export const dynamic = "force-dynamic";

export default async function ImpactMethodologyPage() {
  const result = await getImpactMethodology();
  return (
    <div className="flex max-w-[1500px] flex-col gap-6">
      <PageHeader eyebrow="Impact & Evidence" title="Methodology & KPI dictionary" subtitle="The versioned definition, source, owner, cadence, privacy class, retention, evidence level, and minimum cohort behind every displayed metric." />
      <ImpactNav active="/impact/methodology" />
      {result.error && <DataWarning title="Methodology unavailable">{result.error}</DataWarning>}
      <Card title="Metric contracts" hint="A reporting number without this metadata is not an official Venttly metric" padded={false}>
        <div className="overflow-x-auto"><table className="data-table"><thead><tr><th>Metric</th><th>Pillar / evidence</th><th>Definition & formula</th><th>Source / owner</th><th>Privacy</th><th>Retention / cohort</th><th>Status</th></tr></thead><tbody>
          {result.data.map((metric) => <tr key={metric.metric_key}>
            <td><p className="font-semibold text-burgundy">{metric.title}</p><p className="font-mono text-[11px] text-ink-muted">{metric.metric_key} · {metric.methodology_version}</p></td>
            <td><p className="text-xs font-semibold text-burgundy">{metric.pillar}</p><p className="text-xs text-ink-muted">{metric.evidence_level.replaceAll("_", " ")}</p></td>
            <td className="max-w-lg"><p className="text-xs text-burgundy">{metric.description}</p><p className="mt-1 text-[11px] text-ink-muted">{metric.formula}</p></td>
            <td><p className="text-xs text-burgundy">{metric.source}</p><p className="text-[11px] text-ink-muted">{metric.owner} · {metric.cadence}</p></td>
            <td><Badge tone={metric.privacy_classification === "HIGHLY_RESTRICTED" ? "danger" : metric.privacy_classification === "CONFIDENTIAL" ? "warn" : "neutral"}>{metric.privacy_classification}</Badge></td>
            <td className="text-xs tabular">{metric.retention_days}d · n≥{metric.minimum_cohort}</td>
            <td><Badge tone={metric.status === "active" ? "ok" : "warn"}>{metric.status.replaceAll("_", " ")}</Badge></td>
          </tr>)}
        </tbody></table></div>
      </Card>
    </div>
  );
}
