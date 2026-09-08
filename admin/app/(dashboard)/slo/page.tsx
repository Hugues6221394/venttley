import Link from "next/link";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge, type Tone } from "@/components/ui/badge";
import { Tabs } from "@/components/ui/tabs";
import { CheckCircle2, AlertTriangle, Clock } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Slo = {
  section: string;
  metric: string;
  value: number | string | null;
  unit: string;
  target: number | string | null;
  target_kind: "max" | "min" | "none";
  met: boolean | null;
  sample: number;
  needs_sample: boolean;
};

// Below this, a pass on a *rate or percentile* is not evidence of anything:
// "SLA met: 100%" on two observations reads as reassurance while meaning
// nothing. It does not apply to an absolute count of a bad condition — "0 jobs
// stuck right now" is definitive, and calling that a thin sample would render
// the good state as unmeasured, which is the opposite mistake. The RPC says
// which is which via needs_sample.
const MIN_SAMPLE = 20;

const WINDOWS = [7, 30, 90] as const;

function num(v: number | string | null): number | null {
  if (v === null) return null;
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

function fmt(v: number | null, unit: string): string {
  if (v === null) return "—";
  if (unit === "percent") return `${v}%`;
  if (unit === "minutes") {
    if (v < 1) return "<1m";
    if (v < 60) return `${Math.round(v)}m`;
    if (v < 1440) return `${(v / 60).toFixed(1)}h`;
    return `${(v / 1440).toFixed(1)}d`;
  }
  return `${v}`;
}

export default async function SloPage({
  searchParams,
}: {
  searchParams: Promise<{ days?: string }>;
}) {
  const { days } = await searchParams;
  const parsed = Number(days);
  const window = (WINDOWS as readonly number[]).includes(parsed) ? parsed : 30;

  let rows: Slo[] = [];
  let error: string | null = null;
  try {
    rows = (await rpc<Slo[]>("admin_moderation_slo", { p_days: window })) ?? [];
  } catch (e) {
    error = e instanceof Error ? e.message : "Could not load metrics.";
  }

  const sections = rows.reduce<Record<string, Slo[]>>((acc, r) => {
    (acc[r.section] ??= []).push(r);
    return acc;
  }, {});

  // Only a genuine, well-evidenced miss counts as a breach worth surfacing.
  const measurable = (r: Slo) =>
    r.target_kind !== "none" && (!r.needs_sample || r.sample >= MIN_SAMPLE);

  const breaches = rows.filter((r) => measurable(r) && r.met === false).length;
  const thin = rows.filter(
    (r) => r.target_kind !== "none" && !measurable(r)
  ).length;

  return (
    <div className="flex flex-col gap-6 max-w-[1100px]">
      <PageHeader
        eyebrow="Insight"
        title="Service levels"
        subtitle="How fast the queue is worked, how often decisions survive appeal, and whether the pipelines behind them are keeping up. Aggregates only — no authored content is read to build this page."
        actions={
          <Link href="/audit" className="btn-secondary">
            Privileged activity
          </Link>
        }
      />

      <Tabs
        tabs={WINDOWS.map((d) => ({ key: String(d), label: `${d} days` }))}
        active={String(window)}
        basePath="/slo"
        paramKey="days"
      />

      {error && (
        <Card padded>
          <p className="text-sm text-danger">{error}</p>
        </Card>
      )}

      {!error && (
        <Card padded>
          <div className="flex flex-wrap items-center gap-3">
            {breaches === 0 ? (
              <Badge tone="ok" icon={<CheckCircle2 size={11} />}>
                no target missed on a meaningful sample
              </Badge>
            ) : (
              <Badge tone="danger" icon={<AlertTriangle size={11} />}>
                {breaches} target{breaches === 1 ? "" : "s"} missed
              </Badge>
            )}
            {thin > 0 && (
              <Badge tone="neutral" icon={<Clock size={11} />}>
                {thin} not yet measurable
              </Badge>
            )}
          </div>
          <p className="text-[11px] text-ink-muted mt-2">
            A rate or percentile needs at least {MIN_SAMPLE} observations
            before this page calls it met or missed — a pass on two cases is
            not evidence. Point-in-time counts, like how many jobs are stuck
            right now, are judged immediately.
          </p>
        </Card>
      )}

      {Object.entries(sections).map(([section, metrics]) => (
        <Card key={section} title={section} padded={false}>
          <ul className="divide-y divide-line">
            {metrics.map((m) => {
              const v = num(m.value);
              const t = num(m.target);
              const ok = measurable(m);
              const tone: Tone = !ok ? "neutral" : m.met ? "ok" : "danger";

              return (
                <li
                  key={m.metric}
                  className="px-5 py-3 flex flex-wrap items-center gap-3"
                >
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-semibold text-burgundy">
                      {m.metric}
                    </p>
                    <p className="text-[11px] text-ink-muted">
                      {t !== null
                        ? `target ${m.target_kind === "max" ? "≤" : "≥"} ${fmt(t, m.unit)}`
                        : "tracked, no target set"}
                      {m.needs_sample
                        ? ` · ${m.sample} observation${m.sample === 1 ? "" : "s"}`
                        : " · point in time"}
                    </p>
                  </div>

                  <span className="tabular text-lg font-extrabold text-burgundy">
                    {fmt(v, m.unit)}
                  </span>

                  {m.target_kind === "none" ? null : !ok ? (
                    <Badge tone="neutral">thin sample</Badge>
                  ) : (
                    <Badge tone={tone}>{m.met ? "met" : "missed"}</Badge>
                  )}
                </li>
              );
            })}
          </ul>
        </Card>
      ))}

      <Card padded>
        <p className="h-eyebrow mb-1">Not measured, and why</p>
        <ul className="text-xs text-ink-muted list-disc ml-4 space-y-1">
          <li>
            <b>Audit-write failure rate.</b> Nothing records a failed audit
            write. Audit rows are written inside the same transaction as the
            action they describe, so a failure rolls the action back and leaves
            no trace — by design. Measuring it means logging failures outside
            that transaction.
          </li>
          <li>
            <b>In-app notification delivery.</b>{" "}
            <code className="font-mono">notifications</code> records{" "}
            <code className="font-mono">is_read</code> but no delivery
            timestamp, so &ldquo;delivered&rdquo; cannot be told apart from
            &ldquo;inserted&rdquo;. Push delivery is reported above because{" "}
            <code className="font-mono">push_delivery_outbox</code> does track
            an outcome.
          </li>
          <li>
            <b>Targets are provisional.</b> The 15-minute crisis target is the
            product&rsquo;s own, from the case SLA policy. The rest are
            engineering placeholders, not decisions anyone has signed off.
          </li>
        </ul>
      </Card>
    </div>
  );
}
