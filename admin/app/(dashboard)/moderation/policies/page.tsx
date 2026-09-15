import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice } from "@/components/ui/operations";
import { BookOpenCheck } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Rule = { rule_id: string; category: string; action: string; match_type: string; is_active: boolean; created_at: string };
type CasePolicy = { policy_code: string; decision: string | null; decided_at: string | null };

export default async function PoliciesPage() {
  const db = await createAdminClient();
  const [rulesResult, policiesResult] = await Promise.all([
    db.from("automod_rules").select("rule_id, category, action, match_type, is_active, created_at").order("created_at", { ascending: false }).limit(1000),
    db.from("moderation_cases").select("policy_code, decision, decided_at").not("policy_code", "is", null).order("decided_at", { ascending: false }).limit(500),
  ]);
  const errors = [rulesResult.error, policiesResult.error].filter(Boolean).map((error) => error!.message);
  const rules = (rulesResult.data ?? []) as Rule[];
  const casePolicies = (policiesResult.data ?? []) as CasePolicy[];
  const usage = new Map<string, { count: number; last: string | null; decisions: Set<string> }>();
  for (const item of casePolicies) {
    const current = usage.get(item.policy_code) ?? { count: 0, last: null, decisions: new Set<string>() };
    current.count += 1;
    current.last ??= item.decided_at;
    if (item.decision) current.decisions.add(item.decision);
    usage.set(item.policy_code, current);
  }
  const categories = rules.reduce<Record<string, { active: number; total: number; actions: Set<string> }>>((acc, rule) => {
    const row = (acc[rule.category] ??= { active: 0, total: 0, actions: new Set<string>() });
    row.total += 1;
    if (rule.is_active) row.active += 1;
    row.actions.add(rule.action);
    return acc;
  }, {});

  return (
    <div className="flex max-w-[1100px] flex-col gap-6">
      <PageHeader eyebrow="Operate" title="Moderation policy center" subtitle="A truthful view of the rules the product can currently enforce and the policy codes moderators have actually used." actions={<Link href="/automod" className="btn-secondary">Manage automod rules</Link>} />
      {errors.length > 0 && <ErrorPanel title="Policy evidence is incomplete" detail={errors.join("\n")} />}
      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card title="Automod coverage" hint={`${rules.filter((rule) => rule.is_active).length} active · ${rules.length} total`} padded={false}>
          {Object.keys(categories).length === 0 ? <EmptyState icon={<BookOpenCheck size={30} />} title="No automod categories returned." hint={errors.length ? "A source failed." : "Create rules in Automod to establish enforceable keyword coverage."} /> : <ul className="divide-y divide-line">{Object.entries(categories).sort(([a], [b]) => a.localeCompare(b)).map(([category, item]) => <li key={category} className="flex items-center gap-3 px-5 py-3"><p className="flex-1 text-sm font-bold text-burgundy">{category.replaceAll("_", " ")}</p><span className="text-xs text-ink-muted">{[...item.actions].join(", ")}</span><Badge tone={item.active > 0 ? "ok" : "neutral"}>{item.active}/{item.total} active</Badge></li>)}</ul>}
        </Card>
        <Card title="Observed decision codes" hint="Latest 500 coded decisions; this is a sample, not a complete policy registry" padded={false}>
          {usage.size === 0 ? <EmptyState icon={<BookOpenCheck size={30} />} title="No policy codes returned." hint="Moderators may not have recorded a coded decision yet." /> : <ul className="divide-y divide-line">{[...usage.entries()].sort((a, b) => b[1].count - a[1].count).map(([code, item]) => <li key={code} className="px-5 py-3"><div className="flex items-center gap-2"><code className="font-mono text-sm font-bold text-burgundy">{code}</code><Badge tone="info">{item.count} uses</Badge></div><p className="mt-1 text-xs text-ink-muted">{[...item.decisions].map((value) => value.replaceAll("_", " ")).join(", ") || "No recorded outcome"}{item.last ? ` · last ${new Date(item.last).toLocaleDateString()}` : ""}</p></li>)}</ul>}
        </Card>
      </div>
      <CapabilityNotice title="Venttly does not yet have a versioned policy registry">
        A production policy system needs versioned rules, locale-aware guidance,
        severity/action mappings, publication approvals, effective dates,
        rollback, training acknowledgement, and a decision-time policy snapshot.
        The codes above are evidence of usage, not proof those controls exist.
      </CapabilityNotice>
    </div>
  );
}
