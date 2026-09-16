import { getImpactMetrics, impactRange, type ImpactMetric } from "@/lib/impact";
import { ImpactNav, ImpactRangeLinks } from "@/components/impact-nav";
import { PageHeader } from "@/components/ui/page-header";
import { Card, Row } from "@/components/ui/section";
import { StatCard } from "@/components/ui/stat-card";
import { Badge, type Tone } from "@/components/ui/badge";
import { DataWarning } from "@/components/ui/operations";

export async function ImpactMetricPage({
  active,
  title,
  subtitle,
  pillars,
  rangeValue,
  children,
}: {
  active: string;
  title: string;
  subtitle: string;
  pillars: ImpactMetric["pillar"][];
  rangeValue?: string;
  children?: React.ReactNode;
}) {
  const range = impactRange(rangeValue);
  const result = await getImpactMetrics(range);
  const metrics = result.data.filter((metric) => pillars.includes(metric.pillar));

  return (
    <div className="flex max-w-[1380px] flex-col gap-6">
      <PageHeader
        eyebrow="Impact & Evidence"
        title={title}
        subtitle={subtitle}
        actions={<ImpactRangeLinks active={range.days} path={active} />}
      />
      <ImpactNav active={active} />
      {children}
      {result.error && (
        <DataWarning title="Impact aggregate unavailable">{result.error}</DataWarning>
      )}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        {metrics.map((metric) => (
          <StatCard
            key={metric.metric_key}
            label={metric.title}
            value={displayMetric(metric)}
            sub={metricSub(metric)}
            trend={metric.percent_change === null ? null : Number(metric.percent_change)}
            tone={metricTone(metric)}
          />
        ))}
      </div>
      <Card title="Evidence register" hint={`${range.start} to ${range.end} · aggregate-only`} padded={false}>
        {metrics.length === 0 ? (
          <p className="p-5 text-sm text-ink-muted">No metric definitions are available for this view.</p>
        ) : (
          <div className="px-5 py-2">
            {metrics.map((metric) => (
              <Row
                key={metric.metric_key}
                label={metric.title}
                hint={`${metric.description} · Source: ${metric.source} · ${metric.formula}`}
                value={
                  <div className="flex flex-wrap justify-end gap-1">
                    <Badge tone={qualityTone(metric.quality_status)}>{metric.quality_status}</Badge>
                    <Badge tone={metric.status === "active" ? "info" : "warn"}>{metric.status.replaceAll("_", " ")}</Badge>
                    <Badge tone="neutral">n={metric.sample_size.toLocaleString()}</Badge>
                  </div>
                }
              />
            ))}
          </div>
        )}
      </Card>
    </div>
  );
}

function displayMetric(metric: ImpactMetric): string | number {
  if (metric.status === "governance_gated") return "Not collecting";
  if (metric.suppressed) return "Suppressed";
  if (metric.metric_value === null) return "Unavailable";
  const value = Number(metric.metric_value);
  if (!Number.isFinite(value)) return String(metric.metric_value);
  if (metric.metric_key.includes("rate") || metric.metric_key === "retention.day_7") return `${value.toFixed(1)}%`;
  if (metric.metric_key === "community.time_to_first_support") return `${Math.round(value)}m`;
  return Math.round(value).toLocaleString();
}

function metricSub(metric: ImpactMetric): string {
  if (metric.status === "governance_gated") return "Protocol, consent, and review required";
  if (metric.suppressed) return `Below minimum cohort of ${metric.minimum_cohort}`;
  return `${metric.evidence_level.replaceAll("_", " ")} · n=${metric.sample_size.toLocaleString()}`;
}

function metricTone(metric: ImpactMetric): Tone {
  if (metric.status === "governance_gated" || metric.suppressed) return "warn";
  return qualityTone(metric.quality_status);
}

function qualityTone(status: ImpactMetric["quality_status"]): Tone {
  if (status === "healthy") return "ok";
  if (status === "warning") return "warn";
  if (status === "degraded") return "danger";
  return "neutral";
}
