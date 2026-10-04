import Link from "next/link";
import { randomUUID } from "node:crypto";
import { recoverStaffInvitation, repairStaffInvitationSetup } from "@/lib/staff-invitation-actions";
import { WorkflowForm } from "./workflow-form";
import { readInvitationRegister } from "@/lib/staff-invitation-ledger";
import { INVITATION_PAGE_SIZE, invitationHref, type InvitationCursor } from "@/lib/staff-invitation-model";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { ErrorPanel } from "@/components/ui/empty-state";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";

const stages = {
  reserved: "Attempt reserved · provider outcome unknown",
  provider_accepted: "Provider accepted · access outcome incomplete",
  access_assigned: "Access assignment recorded",
} as const;
function utc(value: string) { return new Date(value).toISOString().replace("T", " ").replace("Z", " UTC"); }

export async function StaffInvitationRegister({ cursor }: { cursor: InvitationCursor }) {
  const register = await readInvitationRegister(cursor);
  const items = register?.enabled ? register.items.slice(0, INVITATION_PAGE_SIZE) : [];
  const next = register?.enabled && register.items.length > INVITATION_PAGE_SIZE ? items.at(-1) : undefined;
  return <div className="flex max-w-[1150px] flex-col gap-6">
    <PageHeader eyebrow="Governance" title="Staff invitations" subtitle="Recorded attempts and partial outcomes. Mailboxes and invitation tokens are never shown in this register."
      actions={<Link href="/staff" className="btn-secondary">Staff directory</Link>} />
    {!register ? <div className="space-y-3"><ErrorPanel title="Invitation register unavailable" detail="The result is unknown, not empty. Refresh to retry; do not send another invitation to diagnose this failure." /><a href="/staff/invitations" className="btn-secondary">Retry from first page</a></div>
      : !register.enabled ? <DataWarning title="Invitation pilot is disabled">The database control is off. New tracked invitations are refused before contacting Auth.</DataWarning>
      : <>
        <p className="text-xs text-ink-muted">Snapshot {utc(register.measured_at)} · up to 25 attempts per page · only attempts created while tracking was enabled are covered.</p>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          {(["reserved", "provider_accepted", "access_assigned"] as const).map(stage => <Card key={stage}>
            <p className="h-eyebrow">{stage === "reserved" ? "Outcome unknown" : stage === "provider_accepted" ? "Access needs review" : "Assignment recorded"} · this page</p>
            <p className="mt-2 text-3xl font-extrabold text-burgundy">{items.filter(item => item.state === stage).length}</p>
          </Card>)}
        </div>
        <Card title="Invitation attempts" hint="Stage history is evidence of recorded progress, not a delivery receipt or current-access certification." padded={false}>
          {items.length === 0 ? <p className="p-5 text-sm text-ink-muted">No attempts on this page. Older or untracked invitations may still exist.</p>
            : <ul className="divide-y divide-line">{items.map(item => <li key={item.invitation_id} className="space-y-3 px-5 py-4">
              <div className="flex flex-wrap items-center gap-2">
                <h2 className="font-bold text-ink">@{item.username}</h2>
                <Badge>{item.requested_role.replaceAll("_", " ")}</Badge>
                <Badge tone={item.state === "access_assigned" ? "neutral" : "warn"}>{stages[item.state]}</Badge>
                {item.cancelled_at ? <Badge tone="warn">Pending grant cancelled</Badge> : item.state !== "access_assigned" && item.grant_expired ? <Badge tone="warn">Grant deadline passed</Badge> : null}
              </div>
              <p className="text-xs text-ink-muted">Requested by {item.requested_by_name} · {utc(item.created_at)}</p>
              <ol aria-label={`Recorded stages for ${item.username}`} className="space-y-1 text-xs text-ink-muted">
                <li>Attempt reserved: {utc(item.created_at)}</li>
                <li>Provider accepted: {item.provider_accepted_at ? utc(item.provider_accepted_at) : "not confirmed"}</li>
                <li>Access assigned: {item.access_assigned_at ? utc(item.access_assigned_at) : "not confirmed"}</li>
              </ol>
              <p className="text-xs text-ink-muted">Current profile: {item.current_role?.replaceAll("_", " ") ?? "unresolved"} · {item.account_status ?? "unknown"}. {item.auth_record_missing ? "The linked Auth record is missing." : item.sign_in_observed ? "A sign-in has been observed; this does not certify MFA or completed setup." : "Completed sign-in is not confirmed."}</p>
              <p className="text-xs text-ink-muted">Pending grant deadline: {utc(item.grant_expires_at)}. This is not the Auth link expiry and does not revoke access already assigned.</p>
              {item.state !== "access_assigned" && <details className="text-sm">
                <summary className="cursor-pointer font-semibold">Investigate and recover</summary>
                <div className="mt-3 grid gap-4 md:grid-cols-2">
                  {(["reconcile", ...(!item.cancelled_at ? ["cancel"] : []), ...(!item.cancelled_at && !item.grant_expired && item.state === "provider_accepted" && item.setup_ready && item.current_role === "normal" ? ["complete_grant"] : [])] as const).map(command => <WorkflowForm
                    key={`${item.version}:${command}`} action={recoverStaffInvitation} blockUncertainRetry
                    disabled={command === "complete_grant" && process.env.ADMIN_STAFF_INVITES_DISABLED === "true"}
                    label={command === "reconcile" ? "Reconcile account evidence" : command === "cancel" ? "Cancel pending grant" : "Complete requested role grant"}
                    confirmation={command === "reconcile" ? "Inspect the account matching this invitation's immutable handle and creation evidence. Record progress only; do not grant access or send mail." : command === "cancel" ? "Permanently block this invitation's pending role grant. This does not revoke an Auth email link or existing staff access. The server refuses cancellation if staff access already exists." : "Grant only this invitation's recorded role to its verified, active, non-staff account. This revokes existing sessions and is audited. Conflicting, cancelled or expired attempts are refused."}>
                    <input type="hidden" name="operation_id" value={randomUUID()} />
                    <input type="hidden" name="invitation_id" value={item.invitation_id} />
                    <input type="hidden" name="version" value={item.version} />
                    <input type="hidden" name="command" value={command} />
                  </WorkflowForm>)}
                </div>
                {!item.setup_ready && item.state === "provider_accepted" && <p className="mt-3 text-xs text-ink-muted">The Auth setup marker is not confirmed. Role completion remains blocked. Missing setup is not evidence that it is safe to reopen an account.</p>}
                {process.env.ADMIN_INVITATION_SETUP_REPAIR_UI === "true" && !item.setup_ready && !item.cancelled_at && !item.grant_expired
                  && item.state === "provider_accepted" && item.current_role === "normal" && item.account_status === "active"
                  && !item.sign_in_observed && !item.auth_record_missing && <div className="mt-3">
                  <WorkflowForm key={`setup:${item.version}`} action={repairStaffInvitationSetup} blockUncertainRetry
                    disabled={process.env.ADMIN_STAFF_INVITES_DISABLED === "true"}
                    label="Check and repair missing setup"
                    confirmation="Ask the server to repair only a missing setup marker on this unused invitation. It refuses accounts with a password, sign-in, existing setup marker or changed standing. This does not send mail, change a password or grant access. Refresh afterward before any separate role grant.">
                    <input type="hidden" name="operation_id" value={randomUUID()} />
                    <input type="hidden" name="invitation_id" value={item.invitation_id} />
                    <input type="hidden" name="version" value={item.version} />
                  </WorkflowForm>
                </div>}
              </details>}
              <details className="text-xs text-ink-muted"><summary className="cursor-pointer">Technical reference</summary><code className="mt-2 block break-all">{item.invitation_id}</code></details>
            </li>)}</ul>}
        </Card>
        <nav aria-label="Invitation pages" className="flex flex-wrap gap-3">
          <a href="/staff/invitations" className="btn-secondary">Refresh / first page</a>
          {next && <Link href={invitationHref(next)} className="btn-secondary">Older attempts</Link>}
        </nav>
      </>}
    <CapabilityNotice title="Reconcile uncertain results before another attempt">
      A replay never sends another invitation. Reconciliation records evidence;
      cancellation and the deadline block pending role grants only. Email resend,
      Auth-link revocation and automatic retries remain unavailable. Where enabled,
      setup repair is an explicit server-checked operation for unused invitations only. Inspect the staff
      directory and audit trail; use the existing separately authorized controls
      for access changes. A reserved attempt can already have created an Auth
      account if its response was lost. Provider acceptance does not prove delivery.
    </CapabilityNotice>
  </div>;
}
