import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { UserSearch } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Candidate = {
  user_id: string;
  display_name: string;
  anonymous_pseudonym: string;
  account_status: string;
  shadow_banned: boolean;
  suspension_count: number;
  posting_cooldown_until: string | null;
  last_seen_at: string | null;
};

type CaseSignal = {
  case_id: string;
  subject_id: string | null;
  severity: string;
  policy_code: string | null;
  report_count: number;
  status: string;
  updated_at: string;
};

export default async function IntegrityPage() {
  const db = await createAdminClient();
  const now = new Date().toISOString();
  const dayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const [blockedLogins, failedLogins, shadowCount, cooldownCount, repeatCount, shadows, cooldowns, repeat, casesResult] = await Promise.all([
    db.from("login_attempts").select("attempt_id", { count: "exact", head: true }).eq("outcome", "blocked").gte("created_at", dayAgo),
    db.from("login_attempts").select("attempt_id", { count: "exact", head: true }).eq("outcome", "failed").gte("created_at", dayAgo),
    db.from("users").select("user_id", { count: "exact", head: true }).eq("shadow_banned", true),
    db.from("users").select("user_id", { count: "exact", head: true }).gt("posting_cooldown_until", now),
    db.from("users").select("user_id", { count: "exact", head: true }).gte("suspension_count", 2),
    db.from("users").select("user_id, display_name, anonymous_pseudonym, account_status, shadow_banned, suspension_count, posting_cooldown_until, last_seen_at").eq("shadow_banned", true).order("last_seen_at", { ascending: false }).limit(30),
    db.from("users").select("user_id, display_name, anonymous_pseudonym, account_status, shadow_banned, suspension_count, posting_cooldown_until, last_seen_at").gt("posting_cooldown_until", now).order("posting_cooldown_until", { ascending: false }).limit(30),
    db.from("users").select("user_id, display_name, anonymous_pseudonym, account_status, shadow_banned, suspension_count, posting_cooldown_until, last_seen_at").gte("suspension_count", 2).order("suspension_count", { ascending: false }).limit(30),
    db.from("moderation_cases").select("case_id, subject_id, severity, policy_code, report_count, status, updated_at").neq("status", "resolved").gte("report_count", 3).order("report_count", { ascending: false }).limit(40),
  ]);
  const results = [blockedLogins, failedLogins, shadowCount, cooldownCount, repeatCount, shadows, cooldowns, repeat, casesResult];
  const errors = results.flatMap((result) => result.error ? [result.error.message] : []);
  const candidates = new Map<string, Candidate>();
  for (const row of [...(shadows.data ?? []), ...(cooldowns.data ?? []), ...(repeat.data ?? [])] as Candidate[]) candidates.set(row.user_id, row);
  const cases = (casesResult.data ?? []) as CaseSignal[];

  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader eyebrow="Operate" title="Platform integrity" subtitle="Server-recorded enforcement and manipulation pressure. Raw IPs, device identifiers, message bodies, and private identity are omitted." actions={<Link href="/moderation/abuse" className="btn-secondary">Abuse controls</Link>} />
      <DataWarning caveat title="These signals do not prove coordinated abuse">
        Suspensions, cooldowns, reports, and blocked logins are triage inputs.
        Treating them as automatic guilt would make coordinated false-reporting
        itself an effective attack.
      </DataWarning>
      {errors.length > 0 && <ErrorPanel title="Integrity picture is incomplete" detail={errors.join("\n")} />}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
        <Metric label="Blocked logins · 24h" value={blockedLogins.count} tone={(blockedLogins.count ?? 0) > 0 ? "warn" : "ok"} />
        <Metric label="Failed logins · 24h" value={failedLogins.count} tone={(failedLogins.count ?? 0) > 100 ? "danger" : "neutral"} />
        <Metric label="Shadow restricted" value={shadowCount.count} tone={(shadowCount.count ?? 0) > 0 ? "info" : "ok"} />
        <Metric label="Posting cooldowns" value={cooldownCount.count} tone={(cooldownCount.count ?? 0) > 0 ? "warn" : "ok"} />
        <Metric label="Repeat suspensions" value={repeatCount.count} tone={(repeatCount.count ?? 0) > 0 ? "warn" : "ok"} />
      </div>
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Account-level integrity candidates" hint="Union of active restrictions and repeat suspensions" padded={false}>
          {candidates.size === 0 ? <EmptyState icon={<UserSearch size={32} />} title="No account candidates returned." hint={errors.length ? "The result is incomplete." : "No current restriction or repeat-suspension signal matched."} /> : (
            <ul className="divide-y divide-line">
              {[...candidates.values()].slice(0, 50).map((row) => (
                <li key={row.user_id} className="px-5 py-3">
                  <div className="flex flex-wrap items-center gap-2">
                    <Link href={`/users/${row.user_id}`} className="font-bold text-burgundy hover:text-berry">{row.display_name}</Link>
                    <span className="text-xs text-ink-muted">@{row.anonymous_pseudonym}</span>
                    {row.shadow_banned && <Badge tone="info">shadow restricted</Badge>}
                    {row.suspension_count >= 2 && <Badge tone="warn">{row.suspension_count} suspensions</Badge>}
                    {row.posting_cooldown_until && new Date(row.posting_cooldown_until) > new Date() && <Badge tone="danger">cooldown active</Badge>}
                  </div>
                  <p className="mt-1 text-[11px] text-ink-muted">{row.account_status} · {row.last_seen_at ? `last seen ${new Date(row.last_seen_at).toLocaleString()}` : "never seen"}</p>
                </li>
              ))}
            </ul>
          )}
        </Card>
        <Card title="Concentrated-report cases" hint="Open cases with at least three source reports" padded={false}>
          {cases.length === 0 ? <EmptyState icon={<UserSearch size={32} />} title="No concentrated-report cases returned." hint={errors.length ? "The source is incomplete." : "No open case crossed the current review threshold."} /> : (
            <ul className="divide-y divide-line">
              {cases.map((row) => (
                <li key={row.case_id} className="px-5 py-3">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge tone={row.severity === "critical" ? "danger" : "warn"}>{row.severity}</Badge>
                    <Badge>{row.report_count} reports</Badge>
                    <span className="text-xs text-ink-muted">{row.policy_code ?? "policy unclassified"}</span>
                  </div>
                  <Link href={`/moderation/cases/${row.case_id}`} className="mt-1 block text-xs font-bold text-berry hover:underline">Open case dossier</Link>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
      <CapabilityNotice title="Cluster detection needs a privacy-reviewed server model">
        Ban-evasion and coordinated-campaign detection require bounded retention,
        pseudonymous linkage, explainable signals, appeal support, and protection
        against false-positive mass enforcement. This page does not expose a raw
        device graph or provide one-click cluster bans.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, tone }: { label: string; value: number | null; tone: "neutral" | "ok" | "warn" | "danger" | "info" }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-2xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : tone}>{value === null ? "unknown" : tone}</Badge></div></Card>;
}
