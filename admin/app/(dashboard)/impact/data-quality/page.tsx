import { ImpactNav } from "@/components/impact-nav";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge, type Tone } from "@/components/ui/badge";
import { DataWarning } from "@/components/ui/operations";
import { getImpactDataQuality } from "@/lib/impact";

export const dynamic = "force-dynamic";

export default async function ImpactDataQualityPage() {
  const result = await getImpactDataQuality();
  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader eyebrow="Impact & Evidence" title="Data quality" subtitle="Freshness, taxonomy, counter, geography, and timestamp checks that determine whether an impact number may be trusted." />
      <ImpactNav active="/impact/data-quality" />
      {result.error && <DataWarning title="Quality run unavailable">{result.error}</DataWarning>}
      <Card title="Latest quality run" hint={result.data[0] ? `As of ${result.data[0].as_of_date}` : "No run recorded"} padded={false}>
        {result.data.length === 0 ? <p className="p-5 text-sm text-ink-muted">No data-quality run is available. Impact metrics must be treated as unavailable until the scheduled job succeeds.</p> : (
          <div className="overflow-x-auto"><table className="data-table"><thead><tr><th>Check</th><th>Status</th><th>Observed</th><th>Threshold</th><th>Meaning</th><th>Checked</th></tr></thead><tbody>
            {result.data.map((check) => <tr key={check.check_key}>
              <td className="font-mono text-xs text-burgundy">{check.check_key}</td>
              <td><Badge tone={tone(check.status)}>{check.status}</Badge></td>
              <td className="tabular">{check.observed_value ?? "—"}</td><td className="tabular">{check.threshold ?? "—"}</td>
              <td className="max-w-md text-xs text-ink-muted">{check.detail}</td><td className="whitespace-nowrap text-xs text-ink-muted">{new Date(check.checked_at).toLocaleString()}</td>
            </tr>)}
          </tbody></table></div>
        )}
      </Card>
    </div>
  );
}

function tone(status: string): Tone {
  return status === "healthy" ? "ok" : status === "warning" ? "warn" : status === "degraded" ? "danger" : "neutral";
}
