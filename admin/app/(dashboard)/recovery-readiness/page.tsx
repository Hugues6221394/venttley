import { randomUUID } from "node:crypto";
import { completeRecoveryDrill, scheduleRecoveryDrill, verifyRecoveryDrill } from "./actions";
import { WorkflowForm } from "@/components/workflows/workflow-form";
import { Badge } from "@/components/ui/badge";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { getOperationalRole, getRecoveryDrills } from "@/lib/governance";

export const dynamic = "force-dynamic";

export default async function RecoveryReadinessPage() {
  const [drills, role] = await Promise.all([getRecoveryDrills(), getOperationalRole()]);
  const isSuper = role === "super_admin";
  const scheduleDefault = new Date(Date.now() + 86_400_000).toISOString().slice(0, 16);
  return <div className="flex max-w-[1500px] flex-col gap-6">
    <PageHeader eyebrow="Resilience" title="Recovery readiness" subtitle="Evidence-backed restore drills with explicit RPO/RTO targets and independent verification. A deployment document is not proof of recoverability." />
    {drills.error && <DataWarning title="Recovery register unavailable">The register could not be loaded. Its status is unknown; try refreshing.</DataWarning>}
    <Card title="Schedule drill" hint="Admin or super admin · AAL2 required · use an isolated restore environment whenever possible">
      <WorkflowForm action={scheduleRecoveryDrill} label="Schedule drill" confirmation="Register a recovery drill with these UTC times and targets. This does not execute a restore." blockUncertainRetry><div className="grid grid-cols-1 gap-4 md:grid-cols-4">
        <input type="hidden" name="operation_id" value={randomUUID()} />
        <label className="field-label">Environment<select name="environment" className="input mt-1" defaultValue="isolated_restore"><option value="staging">Staging</option><option value="isolated_restore">Isolated restore</option><option value="production_recovery_test">Production recovery test</option></select></label>
        <label className="field-label">Scheduled at (UTC)<input type="datetime-local" name="scheduled_at" className="input mt-1" required defaultValue={scheduleDefault} /></label>
        <label className="field-label">Expected RPO (minutes)<input type="number" name="expected_rpo_minutes" className="input mt-1" min={0} max={10080} required defaultValue={60} /></label>
        <label className="field-label">Expected RTO (minutes)<input type="number" name="expected_rto_minutes" className="input mt-1" min={1} max={10080} required defaultValue={120} /></label>
      </div></WorkflowForm>
    </Card>
    <Card title="Drill register" hint={`${drills.data.length} latest drills`} padded={false}>
      {drills.data.length === 0 ? <p className="p-5 text-sm text-ink-muted">{drills.error ? "Recovery drills could not be verified." : "No recovery drill has been registered."}</p> : <div className="overflow-x-auto"><table className="data-table"><thead><tr><th>Drill</th><th>Targets / result</th><th>Evidence</th><th>Controlled action</th></tr></thead><tbody>
        {drills.data.map((item) => {
          const completable = item.status === "scheduled" || item.status === "running";
          const verifiable = item.status === "passed" || item.status === "failed";
          return <tr key={item.recovery_drill_id}>
            <td><p className="font-semibold text-burgundy">{item.environment.replaceAll("_", " ")}</p><p className="text-xs text-ink-muted">{new Date(item.scheduled_at).toISOString().replace("T", " ").slice(0, 16)} UTC</p><p className="font-mono text-[10px] text-ink-muted">{item.recovery_drill_id}</p></td>
            <td><Badge tone={item.status === "verified" ? "neutral" : item.status === "failed" ? "danger" : "warn"}>{item.status}</Badge><p className="mt-1 text-xs">Target RPO {item.expected_rpo_minutes}m · RTO {item.expected_rto_minutes}m</p>{item.actual_rpo_minutes !== null && <p className="text-[11px] text-ink-muted">Actual RPO {item.actual_rpo_minutes}m · RTO {item.actual_rto_minutes}m</p>}</td>
            <td className="text-xs"><p>{item.evidence_recorded ? "SHA-256 evidence recorded" : "No evidence recorded"}</p>{item.checks_total !== null && <p className="text-ink-muted">Checks {item.checks_passed}/{item.checks_total}</p>}</td>
            <td>{completable ? <WorkflowForm action={completeRecoveryDrill} label="Record results" confirmation="Record measured results and the external evidence digest. A different super admin must verify this evidence." blockUncertainRetry><div className="grid min-w-[560px] grid-cols-3 gap-2">
              <input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="drill_id" value={item.recovery_drill_id} />
              <label className="field-label">Outcome<select name="outcome" className="select mt-1" defaultValue="passed"><option value="passed">Passed</option><option value="failed">Failed</option></select></label>
              <label className="field-label">Actual RPO<input type="number" name="actual_rpo_minutes" className="input mt-1" min={0} max={10080} required /></label>
              <label className="field-label">Actual RTO<input type="number" name="actual_rto_minutes" className="input mt-1" min={0} max={10080} required /></label>
              <label className="field-label">Checks passed<input type="number" name="checks_passed" className="input mt-1" min={0} required /></label>
              <label className="field-label">Checks total<input type="number" name="checks_total" className="input mt-1" min={1} required /></label>
              <label className="field-label">Evidence SHA-256<input name="evidence_hash" className="input mt-1 font-mono" minLength={64} maxLength={64} required /></label>
            </div></WorkflowForm> : verifiable && isSuper ? <WorkflowForm action={verifyRecoveryDrill} label="Independently verify" confirmation="Record your independent review of the evidence. Verification records review, not that recovery targets were met." blockUncertainRetry><input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="drill_id" value={item.recovery_drill_id} /></WorkflowForm> : <span className="text-xs text-ink-muted">{verifiable ? "Different super admin must verify" : "No action required"}</span>}</td>
          </tr>;
        })}
      </tbody></table></div>}
    </Card>
    <CapabilityNotice title="Evidence, not backup existence">A drill is only verified after restore timing, integrity checks, and an external evidence digest are recorded and reviewed by a different super admin. Evidence files and credentials remain outside the browser-facing database contract.</CapabilityNotice>
  </div>;
}
