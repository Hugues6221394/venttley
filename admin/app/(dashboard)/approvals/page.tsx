import Link from "next/link";
import { notFound } from "next/navigation";
import { getOperationalRole } from "@/lib/governance";
import { promotionFilters } from "@/lib/promotion-model";
import { PromotionRegister } from "@/components/workflows/promotion-register";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { Scale } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type AuditRow = {
  audit_id: string;
  actor_pseudonym: string;
  actor_role: string;
  action: string;
  target_type: string;
  target_id: string | null;
  reason: string | null;
  created_at: string;
};

const HIGH_IMPACT = /delete|role|super_admin|broadcast|legal_hold|evidence|feature_flag|password_reset|csam/i;

const REQUIRED_CONTROLS = [
  { capability: "Super-admin promotion", current: "deployment-dependent enforcement", target: "AAL2 requester plus independent AAL2 approver", href: "/staff" },
  { capability: "Permanent member deletion", current: "single authorized actor", target: "approval plus legal-hold recheck", href: "/privacy" },
  { capability: "Global broadcast", current: "deployment-dependent enforcement", target: "exact preview, independent approval, idempotent publication", href: "/broadcasts" },
  { capability: "Sensitive evidence export", current: "reason and audit", target: "time-bound approval and download expiry", href: "/evidence-access" },
  { capability: "Critical kill-switch change", current: "single authorized actor", target: "four-eyes approval except emergency stop", href: "/flags" },
] as const;

export default async function ApprovalsPage({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}) {
  if(await getOperationalRole()!=="super_admin")notFound();
  if(process.env.ADMIN_PROMOTION_APPROVALS_UI==="true") {
    const filters=promotionFilters(await searchParams);
    if(!filters)return <div><ErrorPanel title="Invalid approval filters" detail="Use a staff username prefix or restart the queue."/><Link href="/approvals" className="btn-secondary">Reset filters</Link></div>;
    return <PromotionRegister filters={filters}/>;
  }
  if((await searchParams).source!==undefined)return <DataWarning title="Approval interface unavailable">This request requires the separately enabled approval interface. No unrelated record is shown.</DataWarning>;
  const db = await createAdminClient();
  const since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
  const [auditResult, superAdmins] = await Promise.all([
    db
      .from("audit_log")
      .select("audit_id, actor_pseudonym, actor_role, action, target_type, target_id, reason, created_at")
      .gte("created_at", since)
      .order("created_at", { ascending: false })
      .limit(250),
    db
      .from("users")
      .select("user_id", { count: "exact", head: true })
      .eq("user_role", "super_admin")
      .eq("account_status", "active")
      .is("deactivated_at", null),
  ]);
  const recent = ((auditResult.data ?? []) as AuditRow[])
    .filter((row) => HIGH_IMPACT.test(`${row.action} ${row.target_type}`))
    .slice(0, 50);
  const incomplete = Boolean(auditResult.error || superAdmins.error);
  const activeSuperAdmins = superAdmins.error ? null : superAdmins.count;

  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader
        eyebrow="Control"
        title="Sensitive approvals"
        subtitle="High-impact operations and their current authorization posture. This page does not call a single-actor action a two-person approval."
        actions={<Link href="/audit" className="btn-secondary">Open audit log</Link>}
      />

      <DataWarning caveat title="The promotion approval pilot is not visible here">
        This legacy view does not establish whether database promotion enforcement
        is enabled. The new queue is separately gated; hiding it does not disable
        backend enforcement. Other high-impact approvals remain a production gap.
      </DataWarning>

      {incomplete && <ErrorPanel title="Approval posture is incomplete" detail="One or more sources could not be loaded. Refresh to retry; missing evidence is not a healthy state." />}

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Card>
          <p className="h-eyebrow">Active super admins</p>
          <div className="mt-2 flex items-center gap-2">
              <p className="text-3xl font-extrabold text-burgundy">{activeSuperAdmins ?? "—"}</p>
              <Badge tone={activeSuperAdmins === null ? "neutral" : activeSuperAdmins >= 2 ? "ok" : "danger"}>
                {activeSuperAdmins === null ? "unknown" : activeSuperAdmins >= 2 ? "redundant" : "single point"}
            </Badge>
          </div>
        </Card>
        <Card>
          <p className="h-eyebrow">High-impact audit entries · 30d sample</p>
          <p className="mt-2 text-3xl font-extrabold text-burgundy">{auditResult.error ? "—" : recent.length}</p>
          <p className="mt-1 text-xs text-ink-muted">Latest 250 audit rows inspected; this is deliberately labelled a sample.</p>
        </Card>
      </div>

      <Card title="Required approval contracts" hint="Present state versus launch requirement" padded={false}>
        <ul className="divide-y divide-line">
          {REQUIRED_CONTROLS.map((item) => (
            <li key={item.capability} className="grid gap-2 px-5 py-4 md:grid-cols-[1.1fr_1fr_1.4fr_auto] md:items-center">
              <p className="font-bold text-burgundy">{item.capability}</p>
              <div><Badge tone="warn">{item.current}</Badge></div>
              <p className="text-xs text-ink-muted">Required: {item.target}</p>
              <Link href={item.href} className="text-xs font-bold text-berry hover:underline">Inspect</Link>
            </li>
          ))}
        </ul>
      </Card>

      <Card title="Recent high-impact activity" hint="Metadata only; before/after snapshots are available in the restricted audit view" padded={false}>
        {recent.length === 0 ? (
          <EmptyState icon={<Scale size={32} />} title="No matching audit activity returned." hint={auditResult.error ? "The source is incomplete." : "The latest audit sample contains no matching actions."} />
        ) : (
          <ul className="divide-y divide-line">
            {recent.map((row) => (
              <li key={row.audit_id} className="px-5 py-3">
                <div className="flex flex-wrap items-center gap-2">
                  <Badge tone="warn">{row.action}</Badge>
                  <p className="text-sm font-semibold text-burgundy">{row.target_type.replaceAll("_", " ")}</p>
                  <time className="ml-auto text-[11px] text-ink-muted">{new Date(row.created_at).toLocaleString()}</time>
                </div>
                <p className="mt-1 text-xs text-ink-muted">@{row.actor_pseudonym} · {row.actor_role.replaceAll("_", " ")}{row.reason ? ` · ${row.reason.slice(0, 180)}` : " · no reason recorded"}</p>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <CapabilityNotice title="Backend contract required before buttons are enabled">
        Approval creation, independent approval, rejection, expiry, cancellation,
        and one-time execution must be transactional and append-only. UI state
        alone cannot protect a privileged RPC from direct invocation.
      </CapabilityNotice>
    </div>
  );
}
