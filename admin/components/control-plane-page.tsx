import Link from "next/link";
import { getControlSnapshot, type ControlSection } from "@/lib/control-plane";
import { PageHeader } from "@/components/ui/page-header";
import { Card, Row } from "@/components/ui/section";
import { StatCard, type Tone } from "@/components/ui/stat-card";
import { Badge } from "@/components/ui/badge";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { CheckCircle2, Lock } from "@/components/ui/icons";

type Metric = {
  key: string;
  label: string;
  sub: string;
  tone?: Tone;
  format?: "number" | "hours" | "date";
};

type Capability = { key: string; label: string; consequence: string };

export type ControlPageConfig = {
  section: ControlSection;
  eyebrow: string;
  title: string;
  subtitle: string;
  metrics: Metric[];
  capabilities: Capability[];
  operatingChecks: string[];
  links?: { href: string; label: string }[];
};

export async function ControlPlanePage({ config }: { config: ControlPageConfig }) {
  const { snapshot, error } = await getControlSnapshot(config.section);
  const values = snapshot?.data ?? {};

  return (
    <div className="flex max-w-[1280px] flex-col gap-6">
      <PageHeader
        eyebrow={config.eyebrow}
        title={config.title}
        subtitle={config.subtitle}
        actions={
          config.links?.length ? (
            <div className="flex flex-wrap gap-2">
              {config.links.map((link) => (
                <Link key={link.href} href={link.href} className="btn-secondary">
                  {link.label}
                </Link>
              ))}
            </div>
          ) : undefined
        }
      />

      {error && (
        <DataWarning title="Live aggregate unavailable">
          {error}. No stale or invented value is shown; retry after checking the
          migration and Supabase health.
        </DataWarning>
      )}

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {config.metrics.map((metric) => (
          <StatCard
            key={metric.key}
            label={metric.label}
            value={formatValue(values[metric.key], metric.format)}
            sub={metric.sub}
            tone={metric.tone ?? "neutral"}
          />
        ))}
      </div>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card title="Production capabilities" hint="Live contract status, not a roadmap claim">
          <div className="flex flex-col">
            {config.capabilities.map((capability) => {
              const ready = values[capability.key] === true;
              return (
                <Row
                  key={capability.key}
                  label={capability.label}
                  hint={ready ? "Backed by a live data contract." : capability.consequence}
                  value={
                    <Badge tone={ready ? "ok" : "warn"}>
                      {ready ? <CheckCircle2 size={11} /> : <Lock size={11} />}
                      {ready ? "available" : "gap"}
                    </Badge>
                  }
                />
              );
            })}
          </div>
        </Card>

        <Card title="Operator checks" hint="Required before acting on this surface">
          <ol className="flex list-decimal flex-col gap-3 pl-5 text-sm text-ink-muted">
            {config.operatingChecks.map((check) => (
              <li key={check} className="pl-1 leading-relaxed">
                {check}
              </li>
            ))}
          </ol>
        </Card>
      </div>

      <CapabilityNotice title="Aggregate-only control surface">
        This page intentionally exposes counts and readiness signals only. It does
        not return authored content, member identity, contact data, provider
        credentials, storage object paths, or raw model explanations. Every
        missing backend capability is labelled as a gap instead of being simulated
        by a decorative button.
      </CapabilityNotice>

      <p className="text-xs text-ink-muted">
        Snapshot: {snapshot ? new Date(snapshot.generated_at).toLocaleString() : "unavailable"}
        {snapshot ? " · privacy classification: aggregate only" : ""}
      </p>
    </div>
  );
}

function formatValue(
  value: string | number | boolean | null | undefined,
  format: Metric["format"] = "number",
): string | number {
  if (value === null || value === undefined || value === "") return "Unavailable";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (format === "date") return new Date(String(value)).toLocaleString();
  const numeric = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(numeric)) return String(value);
  if (format === "hours") return `${numeric.toLocaleString()}h`;
  return numeric;
}
