import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice } from "@/components/ui/operations";
import { UserSearch } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type MemberControl = { user_id: string; display_name: string; anonymous_pseudonym: string; account_status: string; shadow_banned: boolean; posting_cooldown_until: string | null; suspension_count: number };
type Quota = { user_id: string; request_count: number; window_started_at: string };

export default async function AbusePage() {
  const db = await createAdminClient();
  const now = new Date().toISOString();
  const [shadowResult, cooldownResult, quotaResult, recentReports, blockedLogins] = await Promise.all([
    db.from("users").select("user_id, display_name, anonymous_pseudonym, account_status, shadow_banned, posting_cooldown_until, suspension_count").eq("shadow_banned", true).order("updated_at", { ascending: false }).limit(100),
    db.from("users").select("user_id, display_name, anonymous_pseudonym, account_status, shadow_banned, posting_cooldown_until, suspension_count").gt("posting_cooldown_until", now).order("posting_cooldown_until", { ascending: false }).limit(100),
    db.from("moderation_rate_limits").select("user_id, request_count, window_started_at").order("request_count", { ascending: false }).limit(100),
    db.from("reports").select("report_id", { count: "exact", head: true }).gte("created_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()),
    db.from("login_attempts").select("attempt_id", { count: "exact", head: true }).eq("outcome", "blocked").gte("created_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()),
  ]);
  const results = [shadowResult, cooldownResult, quotaResult, recentReports, blockedLogins];
  const errors = results.flatMap((result) => result.error ? [result.error.message] : []);
  const controls = new Map<string, MemberControl>();
  for (const row of [...(shadowResult.data ?? []), ...(cooldownResult.data ?? [])] as MemberControl[]) controls.set(row.user_id, row);
  const quotas = (quotaResult.data ?? []) as Quota[];
  const missingIds = quotas.map((row) => row.user_id).filter((id) => !controls.has(id));
  const peopleResult = missingIds.length > 0 ? await db.from("users").select("user_id, display_name, anonymous_pseudonym, account_status, shadow_banned, posting_cooldown_until, suspension_count").in("user_id", missingIds) : { data: [], error: null };
  if (peopleResult.error) errors.push(peopleResult.error.message);
  for (const row of (peopleResult.data ?? []) as MemberControl[]) controls.set(row.user_id, row);

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader eyebrow="Operate" title="Abuse intelligence" subtitle="Server-recorded restrictions and moderation-request pressure. This page avoids raw IPs, device identifiers, contact data, and authored content." actions={<Link href="/moderation" className="btn-secondary">Case queue</Link>} />
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Shadow restrictions" value={shadowResult.data?.length ?? null} />
        <Metric label="Active posting cooldowns" value={cooldownResult.data?.length ?? null} />
        <Metric label="Reports · 24h" value={recentReports.count} />
        <Metric label="Blocked logins · 24h" value={blockedLogins.count} />
      </div>
      {errors.length > 0 && <ErrorPanel title="Abuse picture is incomplete" detail={errors.join("\n")} />}
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Active account controls" hint={`${controls.size} members across the current capped results`} padded={false}>
          {controls.size === 0 ? <EmptyState icon={<UserSearch size={30} />} title="No active controls returned." hint={errors.length ? "A source failed; this is not proof that none exist." : "No shadow restrictions or active posting cooldowns are in the current result."} /> : <ul className="divide-y divide-line">{[...controls.values()].map((member) => <li key={member.user_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Link href={`/users/${member.user_id}`} className="font-bold text-burgundy hover:text-berry">{member.display_name}</Link><span className="text-xs text-ink-muted">@{member.anonymous_pseudonym}</span>{member.shadow_banned && <Badge tone="danger">shadow restricted</Badge>}{member.posting_cooldown_until && new Date(member.posting_cooldown_until) > new Date() && <Badge tone="warn">cooldown</Badge>}</div><p className="mt-1 text-xs text-ink-muted">status {member.account_status} · {member.suspension_count} prior suspensions{member.posting_cooldown_until ? ` · cooldown until ${new Date(member.posting_cooldown_until).toLocaleString()}` : ""}</p></li>)}</ul>}
        </Card>
        <Card title="Moderation request pressure" hint="Highest counters in the current server windows" padded={false}>
          {quotas.length === 0 ? <EmptyState icon={<UserSearch size={30} />} title="No moderation quota rows returned." hint="Rows are created only when the server-side moderation quota is exercised." /> : <ul className="divide-y divide-line">{quotas.map((quota) => { const member = controls.get(quota.user_id); return <li key={`${quota.user_id}-${quota.window_started_at}`} className="px-5 py-3"><div className="flex items-center gap-2"><Badge tone={quota.request_count >= 20 ? "danger" : quota.request_count >= 10 ? "warn" : "neutral"}>{quota.request_count} requests</Badge><Link href={`/users/${quota.user_id}`} className="font-semibold text-burgundy hover:text-berry">{member?.display_name ?? "Unknown member"}</Link></div><p className="mt-1 text-[11px] text-ink-muted">window began {new Date(quota.window_started_at).toLocaleString()}</p></li>; })}</ul>}
        </Card>
      </div>
      <CapabilityNotice title="Coordinated-abuse detection is not yet implemented">
        Shared-device correlation, ban-evasion confidence, graph clustering,
        raid detection, brigading, and bulk containment need privacy-reviewed
        signals, false-positive controls, auditability, and appeal paths. The
        current data should support investigation, not automated guilt.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: number | null }) {
  return <Card><p className="h-eyebrow">{label}</p><p className="mt-1 text-2xl font-extrabold text-burgundy">{value ?? "—"}</p></Card>;
}
