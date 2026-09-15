import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice } from "@/components/ui/operations";
import { Lock, ShieldAlert } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type SecurityEvent = {
  event_id: string;
  user_id: string;
  kind: string;
  severity: "info" | "warning" | "critical";
  created_at: string;
};

type RiskySession = {
  device_session_id: string;
  user_id: string;
  country: string | null;
  app_version: string | null;
  risk_score: number;
  started_at: string;
  last_seen_at: string;
  revoked_at: string | null;
};

type Person = { user_id: string; display_name: string; anonymous_pseudonym: string };

export default async function SecurityPage() {
  const db = await createAdminClient();
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const [failed, blocked, mfa, critical, eventsResult, sessionsResult] = await Promise.all([
    db.from("login_attempts").select("attempt_id", { count: "exact", head: true }).eq("outcome", "failed").gte("created_at", since),
    db.from("login_attempts").select("attempt_id", { count: "exact", head: true }).eq("outcome", "blocked").gte("created_at", since),
    db.from("login_attempts").select("attempt_id", { count: "exact", head: true }).eq("outcome", "mfa_required").gte("created_at", since),
    db.from("security_events").select("event_id", { count: "exact", head: true }).eq("severity", "critical").gte("created_at", since),
    db.from("security_events").select("event_id, user_id, kind, severity, created_at").in("severity", ["warning", "critical"]).order("created_at", { ascending: false }).limit(50),
    db.from("device_sessions").select("device_session_id, user_id, country, app_version, risk_score, started_at, last_seen_at, revoked_at").gte("risk_score", 60).order("risk_score", { ascending: false }).limit(50),
  ]);
  const results = [failed, blocked, mfa, critical, eventsResult, sessionsResult];
  const errors = results.flatMap((result) => result.error ? [result.error.message] : []);
  const events = (eventsResult.data ?? []) as SecurityEvent[];
  const sessions = (sessionsResult.data ?? []) as RiskySession[];
  const userIds = [...new Set([...events.map((row) => row.user_id), ...sessions.map((row) => row.user_id)])];
  const peopleResult = userIds.length > 0
    ? await db.from("users").select("user_id, display_name, anonymous_pseudonym").in("user_id", userIds)
    : { data: [], error: null };
  if (peopleResult.error) errors.push(peopleResult.error.message);
  const people = new Map(((peopleResult.data ?? []) as Person[]).map((person) => [person.user_id, person]));

  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader eyebrow="Control" title="Security center" subtitle="Account-risk and session outcomes for incident triage. Passwords, recovery material, full IP addresses, device identifiers, and event context are deliberately excluded." actions={<Link href="/sessions" className="btn-secondary">Sessions & IPs</Link>} />
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Failed logins · 24h" value={failed.count} tone={(failed.count ?? 0) > 20 ? "warn" : "neutral"} />
        <Metric label="Blocked logins · 24h" value={blocked.count} tone={(blocked.count ?? 0) > 0 ? "danger" : "ok"} />
        <Metric label="MFA challenges · 24h" value={mfa.count} tone="info" />
        <Metric label="Critical events · 24h" value={critical.count} tone={(critical.count ?? 0) > 0 ? "danger" : "ok"} />
      </div>
      {errors.length > 0 && <ErrorPanel title="Security posture is only partially visible" detail={errors.join("\n")} hint="Never interpret a failed telemetry query as zero incidents." />}
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Warning and critical events" hint={`Latest ${events.length}`} padded={false}>
          {events.length === 0 ? <EmptyState icon={<ShieldAlert size={30} />} title="No warning or critical events returned." hint={errors.length ? "One or more sources failed; this is not a clean bill of health." : "The current event window is quiet."} /> : <ul className="divide-y divide-line">{events.map((event) => { const person = people.get(event.user_id); return <li key={event.event_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Badge tone={event.severity === "critical" ? "danger" : "warn"}>{event.severity}</Badge><p className="text-sm font-bold text-burgundy">{event.kind.replaceAll("_", " ")}</p><time className="ml-auto text-[11px] text-ink-muted">{new Date(event.created_at).toLocaleString()}</time></div><Link href={`/users/${event.user_id}`} className="mt-1 block text-xs text-berry hover:underline">{person?.display_name ?? "Open member"}{person ? ` · @${person.anonymous_pseudonym}` : ""}</Link></li>; })}</ul>}
        </Card>
        <Card title="High-risk device sessions" hint="Risk score 60 or above" padded={false}>
          {sessions.length === 0 ? <EmptyState icon={<Lock size={30} />} title="No high-risk sessions returned." hint={errors.length ? "A source failure prevents a definitive conclusion." : "Review remains available in Sessions & IPs."} /> : <ul className="divide-y divide-line">{sessions.map((session) => { const person = people.get(session.user_id); return <li key={session.device_session_id} className="px-5 py-3"><div className="flex items-center gap-2"><Badge tone={session.risk_score >= 80 ? "danger" : "warn"}>risk {session.risk_score}</Badge>{session.revoked_at && <Badge tone="ok">revoked</Badge>}<span className="ml-auto text-[11px] text-ink-muted">last seen {new Date(session.last_seen_at).toLocaleString()}</span></div><Link href={`/users/${session.user_id}`} className="mt-1 block text-sm font-semibold text-burgundy hover:text-berry">{person?.display_name ?? "Unknown member"}</Link><p className="text-xs text-ink-muted">{session.country ?? "country unknown"} · app {session.app_version ?? "unknown"}</p></li>; })}</ul>}
        </Card>
      </div>
      <CapabilityNotice title="Containment controls are not wired yet">
        Session revocation, forced re-authentication, staff access review, and
        ban-evasion/device blocks need narrowly scoped AAL2-gated RPCs with
        reason capture and append-only audit. This page stays observational
        until those backend guarantees exist.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, tone }: { label: string; value: number | null; tone: "neutral" | "ok" | "warn" | "danger" | "info" }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-2xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : tone}>{value === null ? "unknown" : tone === "ok" ? "clear" : tone}</Badge></div></Card>;
}
