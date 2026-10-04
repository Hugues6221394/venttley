import Link from "next/link";
import { notFound } from "next/navigation";
import { activeStaffRole } from "@/lib/staff";
import { createAdminClient, createSsrClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { Siren } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type AlertRow = { alert_id: string; subsystem: string; severity: string; problem: string; created_at: string };
type CaseRow = { case_id: string; severity: string; policy_code: string | null; status: string; opened_at: string };
export default async function EmergencyAccessPage() {
  const ssr = await createSsrClient();
  const { data: { user } } = await ssr.auth.getUser();
  if (!user) notFound();
  const role = await activeStaffRole(ssr, user.id, ["super_admin"]);
  if (role !== "super_admin") notFound();

  const db = await createAdminClient();
  const [superAdmins, alertsResult, casesResult] = await Promise.all([
    db.from("users").select("user_id", { count: "exact", head: true }).eq("user_role", "super_admin").eq("account_status", "active").is("deactivated_at", null),
    db.from("platform_alerts").select("alert_id, subsystem, severity, problem, created_at").is("resolved_at", null).in("severity", ["high", "critical"]).order("created_at", { ascending: false }).limit(50),
    db.from("moderation_cases").select("case_id, severity, policy_code, status, opened_at").eq("severity", "critical").neq("status", "resolved").order("opened_at", { ascending: false }).limit(50),
  ]);
  const results = [superAdmins, alertsResult, casesResult];
  const errors = results.flatMap((result) => result.error ? [result.error.message] : []);
  const alerts = (alertsResult.data ?? []) as AlertRow[];
  const cases = (casesResult.data ?? []) as CaseRow[];

  return (
    <div className="flex max-w-[1150px] flex-col gap-6">
      <PageHeader
        eyebrow="Control"
        title="Emergency access"
        subtitle="Restricted incident context for Super Admins. This page exposes no secret, bypass token, raw evidence, authored content, IP address, or device identifier."
        actions={<Link href="/incidents" className="btn-secondary">Incident command</Link>}
      />
      <DataWarning caveat title="No canonical break-glass system exists yet">
        There is currently no short-lived emergency grant, independent approval,
        scoped privilege, automatic expiry, or post-use certification. This page
        must not be interpreted as an emergency-access mechanism.
      </DataWarning>
      {errors.length > 0 && <ErrorPanel title="Emergency context is incomplete" detail={errors.join("\n")} hint="Missing telemetry is unknown, not healthy." />}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Metric label="Active Super Admins" value={superAdmins.count} tone={(superAdmins.count ?? 0) < 2 ? "danger" : "ok"} />
        <Metric label="Critical platform alerts" value={alertsResult.error ? null : alerts.length} tone={alerts.length ? "danger" : "ok"} />
        <Metric label="Open critical cases" value={casesResult.error ? null : cases.length} tone={cases.length ? "danger" : "ok"} />
        <Metric label="Emergency grants" value={null} tone="warn" />
      </div>
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <Card title="Critical operational signals" hint="Open platform alerts and cases; content omitted" padded={false}>
          {alerts.length + cases.length === 0 ? (
            <EmptyState icon={<Siren size={32} />} title="No critical records returned." hint={errors.length ? "One or more sources are unavailable." : "This only reflects canonical records, not external monitoring systems."} />
          ) : (
            <ul className="divide-y divide-line">
              {alerts.map((alert) => <li key={alert.alert_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Badge tone="danger">{alert.severity}</Badge><span className="font-bold text-burgundy">{alert.subsystem}</span></div><p className="mt-1 text-xs text-ink-muted">{alert.problem.slice(0, 180)}</p><p className="mt-1 text-[11px] text-ink-muted">{new Date(alert.created_at).toLocaleString()}</p></li>)}
              {cases.map((item) => <li key={item.case_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Badge tone="danger">critical case</Badge><Badge>{item.status}</Badge><span className="text-xs text-ink-muted">{item.policy_code ?? "policy unclassified"}</span></div><Link href={`/moderation/cases/${item.case_id}`} className="mt-1 block text-xs font-bold text-berry hover:underline">Open restricted case dossier</Link></li>)}
            </ul>
          )}
        </Card>
        <Card title="Required operator checks" hint="Existing restricted evidence sources">
          <div className="flex flex-col gap-3 text-sm">
            <Link href="/security" className="surface-flat flex items-center justify-between px-4 py-3 font-bold text-burgundy hover:text-berry"><span>Security events and session posture</span><Badge tone="warn">inspect</Badge></Link>
            <Link href="/audit" className="surface-flat flex items-center justify-between px-4 py-3 font-bold text-burgundy hover:text-berry"><span>Privileged action ledger</span><Badge tone="warn">inspect</Badge></Link>
            <Link href="/evidence-access" className="surface-flat flex items-center justify-between px-4 py-3 font-bold text-burgundy hover:text-berry"><span>Restricted-evidence access</span><Badge tone="warn">inspect</Badge></Link>
          </div>
        </Card>
      </div>
      <CapabilityNotice title="Break-glass access must be temporary and independently governed">
        The backend phase needs hardware-backed MFA, two-person approval,
        incident binding, least-privilege scopes, a short TTL, session revocation,
        tamper-evident audit delivery, external alerting, and mandatory post-use
        review. A permanent hidden superuser would be a vulnerability, not a fix.
      </CapabilityNotice>
    </div>
  );
}

function Metric({ label, value, tone }: { label: string; value: number | null; tone: "ok" | "warn" | "danger" }) {
  return <Card><p className="h-eyebrow">{label}</p><div className="mt-1 flex items-center gap-2"><p className="text-3xl font-extrabold text-burgundy">{value ?? "—"}</p><Badge tone={value === null ? "neutral" : tone}>{value === null ? "unknown" : tone === "ok" ? "clear" : "review"}</Badge></div></Card>;
}
