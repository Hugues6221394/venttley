import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice } from "@/components/ui/operations";
import { ClipboardCheck } from "@/components/ui/icons";

export const dynamic = "force-dynamic";
const SAMPLE_LIMIT = 1000;

type Decision = { case_id: string; decided_by: string; decision: string; opened_at: string; first_action_at: string | null; decided_at: string };
type Appeal = { reviewer_id: string | null; status: string; reviewed_at: string | null };
type Person = { user_id: string; display_name: string; anonymous_pseudonym: string; user_role: string };

export default async function QualityPage() {
  const db = await createAdminClient();
  const since = new Date(Date.now() - 30 * 86_400_000).toISOString();
  const [decisionsResult, appealsResult] = await Promise.all([
    db.from("moderation_cases").select("case_id, decided_by, decision, opened_at, first_action_at, decided_at").not("decided_by", "is", null).gte("decided_at", since).order("decided_at", { ascending: false }).limit(SAMPLE_LIMIT),
    db.from("moderation_appeals").select("reviewer_id, status, reviewed_at").not("reviewed_at", "is", null).gte("reviewed_at", since).limit(SAMPLE_LIMIT),
  ]);
  const errors = [decisionsResult.error, appealsResult.error].filter(Boolean).map((error) => error!.message);
  const decisions = (decisionsResult.data ?? []) as Decision[];
  const appeals = (appealsResult.data ?? []) as Appeal[];
  const reviewerIds = [...new Set([...decisions.map((item) => item.decided_by), ...appeals.map((item) => item.reviewer_id).filter((id): id is string => !!id)])];
  const peopleResult = reviewerIds.length > 0 ? await db.from("users").select("user_id, display_name, anonymous_pseudonym, user_role").in("user_id", reviewerIds) : { data: [], error: null };
  if (peopleResult.error) errors.push(peopleResult.error.message);
  const people = new Map(((peopleResult.data ?? []) as Person[]).map((person) => [person.user_id, person]));
  const byReviewer = new Map<string, { decisions: number; noAction: number; removals: number; appealReviews: number; overturned: number }>();
  for (const decision of decisions) {
    const row = byReviewer.get(decision.decided_by) ?? { decisions: 0, noAction: 0, removals: 0, appealReviews: 0, overturned: 0 };
    row.decisions += 1;
    if (decision.decision === "no_action") row.noAction += 1;
    if (decision.decision === "content_removed") row.removals += 1;
    byReviewer.set(decision.decided_by, row);
  }
  for (const appeal of appeals) {
    if (!appeal.reviewer_id) continue;
    const row = byReviewer.get(appeal.reviewer_id) ?? { decisions: 0, noAction: 0, removals: 0, appealReviews: 0, overturned: 0 };
    row.appealReviews += 1;
    if (appeal.status === "overturned") row.overturned += 1;
    byReviewer.set(appeal.reviewer_id, row);
  }
  const firstActionMinutes = decisions.flatMap((item) => item.first_action_at ? [(new Date(item.first_action_at).getTime() - new Date(item.opened_at).getTime()) / 60_000] : []).filter((value) => Number.isFinite(value) && value >= 0);
  const resolutionMinutes = decisions.map((item) => (new Date(item.decided_at).getTime() - new Date(item.opened_at).getTime()) / 60_000).filter((value) => Number.isFinite(value) && value >= 0);
  const mean = (values: number[]) => values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null;
  const overturned = appeals.filter((item) => item.status === "overturned").length;

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader eyebrow="Insight" title="Moderation quality" subtitle="Thirty-day workload and appeal outcomes without loading reported content. Small samples are shown as samples, not as evidence of staff quality." actions={<Link href="/slo" className="btn-secondary">Service levels</Link>} />
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Decisions" value={decisions.length} suffix={decisions.length === SAMPLE_LIMIT ? "+" : ""} />
        <Metric label="Mean first action" value={formatMinutes(mean(firstActionMinutes))} />
        <Metric label="Mean resolution" value={formatMinutes(mean(resolutionMinutes))} />
        <Metric label="Appeal overturns" value={appeals.length ? `${overturned}/${appeals.length}` : "—"} />
      </div>
      {errors.length > 0 && <ErrorPanel title="Quality sample is incomplete" detail={errors.join("\n")} />}
      <Card title="Reviewer activity" hint="Descriptive workload only; never use volume alone as a performance score" padded={false}>
        {byReviewer.size === 0 ? <EmptyState icon={<ClipboardCheck size={30} />} title="No reviewer activity returned." hint={errors.length ? "A source failed." : "No decisions or appeal reviews were recorded in the last 30 days."} /> : <div className="overflow-x-auto"><table className="w-full text-sm"><thead className="bg-canvas/70"><tr><th className="t-th">Staff member</th><th className="t-th text-right">Decisions</th><th className="t-th text-right">No action</th><th className="t-th text-right">Removed</th><th className="t-th text-right">Appeals reviewed</th><th className="t-th text-right">Overturned</th></tr></thead><tbody>{[...byReviewer.entries()].sort((a, b) => b[1].decisions - a[1].decisions).map(([id, row]) => { const person = people.get(id); return <tr key={id} className="t-row"><td className="t-td"><p className="font-bold text-burgundy">{person?.display_name ?? "Former staff member"}</p>{person && <p className="text-xs text-ink-muted">@{person.anonymous_pseudonym} · {person.user_role}</p>}</td><td className="t-td text-right tabular">{row.decisions}</td><td className="t-td text-right tabular">{row.noAction}</td><td className="t-td text-right tabular">{row.removals}</td><td className="t-td text-right tabular">{row.appealReviews}</td><td className="t-td text-right tabular"><Badge tone={row.appealReviews >= 20 && row.overturned / row.appealReviews > 0.25 ? "warn" : "neutral"}>{row.overturned}</Badge></td></tr>; })}</tbody></table></div>}
      </Card>
      <CapabilityNotice title="Quality review needs sampled case calibration">
        Production quality assurance should randomly sample decisions, compare
        reviewers against a blinded consensus, track policy-version agreement,
        document coaching, and measure false positives and false negatives. The
        current aggregates cannot establish that a moderator is good or bad.
      </CapabilityNotice>
    </div>
  );
}

function formatMinutes(value: number | null): string {
  if (value === null) return "—";
  if (value < 60) return `${Math.round(value)}m`;
  if (value < 1440) return `${(value / 60).toFixed(1)}h`;
  return `${(value / 1440).toFixed(1)}d`;
}

function Metric({ label, value, suffix = "" }: { label: string; value: string | number; suffix?: string }) {
  return <Card><p className="h-eyebrow">{label}</p><p className="mt-1 text-2xl font-extrabold text-burgundy">{value}{suffix}</p></Card>;
}
