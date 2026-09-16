import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/section";
import type { ImpactDimension } from "@/lib/impact";

export function ImpactDimensionTable({
  rows,
  empty,
}: {
  rows: ImpactDimension[];
  empty: string;
}) {
  return (
    <Card title="Cohort distribution" hint="Only cohorts meeting the minimum threshold are returned" padded={false}>
      {rows.length === 0 ? (
        <p className="p-5 text-sm text-ink-muted">{empty}</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="data-table">
            <thead><tr><th>Cohort</th><th>Active-person days</th><th>Aggregate sample</th><th>Quality</th></tr></thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.dimension_value}>
                  <td className="font-semibold text-burgundy">{row.dimension_value.replaceAll("_", " ")}</td>
                  <td className="tabular">{Number(row.metric_value ?? 0).toLocaleString()}</td>
                  <td className="tabular">{row.sample_size.toLocaleString()}</td>
                  <td><Badge tone={row.quality_status === "healthy" ? "ok" : "warn"}>{row.quality_status}</Badge></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}
