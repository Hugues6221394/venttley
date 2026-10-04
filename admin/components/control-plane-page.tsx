import Link from "next/link";
import { Suspense } from "react";
import { notFound } from "next/navigation";
import { getControlSnapshot, type ControlSection } from "@/lib/control-plane";
import { CONTROL_ROUTES, controlMetric, controlCapability } from "@/lib/control-plane-model";
import { getOperationalRole } from "@/lib/governance";
import { canAccess } from "@/lib/roles";
import { PanelSkeleton } from "@/components/ui/operator-workspace";
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
  const role = await getOperationalRole();
  if (!role || !canAccess(role, CONTROL_ROUTES[config.section])) notFound();
  const links = config.links?.filter(link => canAccess(role, link.href));
  const streaming = process.env.ADMIN_CONTROL_WORKSPACES_UI === "true";

  return (
    <div className="flex max-w-[1280px] flex-col gap-6">
      <PageHeader
        eyebrow={config.eyebrow}
        title={config.title}
        subtitle={config.subtitle}
        actions={
          links?.length ? (
            <div className="flex flex-wrap gap-2">
              {links.map((link) => (
                <Link key={link.href} href={link.href} prefetch={false} className="btn-secondary">
                  {link.label}
                </Link>
              ))}
            </div>
          ) : undefined
        }
      />

      {streaming ? <Suspense fallback={<PanelSkeleton label="operational aggregates" />}>
        <ControlSnapshotPanel config={config} />
      </Suspense> : <ControlSnapshotPanel config={config} />}

      <Card title="Operator checks" hint="Required before acting on this surface">
        <ol className="flex list-decimal flex-col gap-3 pl-5 text-sm text-ink-muted">
          {config.operatingChecks.map(check => <li key={check} className="pl-1 leading-relaxed">{check}</li>)}
        </ol>
      </Card>

      <CapabilityNotice title="Aggregate-only control surface">
        Counts and capability signals do not prove successful execution or production
        readiness. Missing or unavailable signals remain unknown. This view does not
        expose authored content, account details, credentials or storage object paths.
      </CapabilityNotice>
    </div>
  );
}

async function ControlSnapshotPanel({ config }: { config: ControlPageConfig }) {
  const { snapshot, error } = await getControlSnapshot(config.section);
  const values = snapshot?.data ?? {};
  return <section className="flex flex-col gap-6" aria-label="Operational aggregates">

      {error && (
        <DataWarning title="Live aggregate unavailable">
          Live aggregates could not be verified. No zero or healthy state is inferred.
          {" "}<a href={CONTROL_ROUTES[config.section]} className="underline">Reload this workspace</a>.
        </DataWarning>
      )}

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {config.metrics.map((metric) => (
          <StatCard
            key={metric.key}
            label={metric.label}
            value={controlMetric(values[metric.key], metric.format)}
            sub={metric.sub}
            tone={metric.tone ?? "neutral"}
          />
        ))}
      </div>

        <Card title="Production capabilities" hint="Live contract status, not a roadmap claim">
          <div className="flex flex-col">
            {config.capabilities.map((capability) => {
              const state = controlCapability(values[capability.key]);
              const ready = state === "available";
              return (
                <Row
                  key={capability.key}
                  label={capability.label}
                  hint={ready ? "Reported by the data contract; execution is not verified here." : state === "unknown" ? "This capability could not be verified." : capability.consequence}
                  value={
                    <Badge tone={ready ? "ok" : state === "unknown" ? "neutral" : "warn"}>
                      {ready ? <CheckCircle2 size={11} /> : <Lock size={11} />}
                      {state}
                    </Badge>
                  }
                />
              );
            })}
          </div>
        </Card>

      <p className="text-xs text-ink-muted">
        Snapshot: {snapshot ? controlMetric(snapshot.generated_at, "date") : "unavailable"}
        {snapshot ? " · privacy classification: aggregate only" : ""}
      </p>
    </section>;
}
