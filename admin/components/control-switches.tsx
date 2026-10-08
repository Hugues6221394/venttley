import { randomUUID } from "node:crypto";
import { createSsrClient } from "@/lib/supabase/server";
import { configureControlSwitch } from "@/lib/control-switch-actions";
import { WorkflowForm } from "./workflows/workflow-form";
import { Card } from "./ui/section";
import { Badge } from "./ui/badge";

type Switches = {
  staff_inbox: { enabled: boolean; moderation_events: boolean; delivery_retention: boolean; job_events: boolean; report_events: boolean; governance_events: boolean } | null;
  access_reviews: boolean | null;
  invitation_ledger: { enabled: boolean; setup_repair: boolean } | null;
  promotion_approvals: boolean | null;
  broadcast_approvals: boolean | null;
  active_super_admins: number;
};

const State = ({ on }: { on: boolean | null | undefined }) =>
  <Badge tone={on === undefined || on === null ? "neutral" : on ? "ok" : "warn"}>{on === undefined || on === null ? "unknown" : on ? "on" : "off"}</Badge>;

function OnOff({ name, label, value }: { name: string; label: string; value: boolean }) {
  return <label className="contact-field"><span>{label}</span>
    <select name={name} className="select" defaultValue={String(value)}><option value="true">On</option><option value="false">Off</option></select>
  </label>;
}

function Toggle({ id, title, detail, on, confirmOn, confirmOff, blocked }: { id: string; title: string; detail: string; on: boolean; confirmOn: string; confirmOff: string; blocked?: string }) {
  return <li className="px-5 py-4">
    <div className="flex flex-wrap items-center gap-2"><p className="font-bold text-burgundy">{title}</p><State on={on} /></div>
    <p className="mt-1 text-xs text-ink-muted">{detail}</p>
    {blocked && !on ? <p className="mt-2 text-xs text-ink-muted">{blocked}</p> : <div className="mt-3">
      <WorkflowForm action={configureControlSwitch} blockUncertainRetry label={on ? `Turn off ${title.toLowerCase()}` : `Turn on ${title.toLowerCase()}`} confirmation={on ? confirmOff : confirmOn}>
        <input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="switch" value={id} /><input type="hidden" name="enabled" value={String(!on)} />
      </WorkflowForm>
    </div>}
  </li>;
}

/** Super admin only. Every change goes through that switch's own MFA-gated, audited RPC. */
export async function ControlSwitches({ invitationKeyConfigured }: { invitationKeyConfigured: boolean }) {
  const db = await createSsrClient();
  const { data, error } = await db.rpc("admin_control_switches");
  if (error || !data) return <Card title="Release controls" padded><p className="text-sm text-ink-muted">Switch states could not be read. Nothing is assumed on or off.</p></Card>;
  const s = data as Switches;
  const inbox = s.staff_inbox;
  return (
    <Card title="Release controls" hint="Each change needs MFA and is audit-logged" padded={false}>
      <ul className="divide-y divide-line">
        {inbox && <li className="px-5 py-4">
          <div className="flex flex-wrap items-center gap-2"><p className="font-bold text-burgundy">Staff notification sources</p>
            {!inbox.enabled && <Badge tone="warn">turn on staff notifications first</Badge>}</div>
          <p className="mt-1 text-xs text-ink-muted">Moderation <State on={inbox.moderation_events} /> · retention <State on={inbox.delivery_retention} /> · failed jobs <State on={inbox.job_events} /> · reports <State on={inbox.report_events} /> · governance <State on={inbox.governance_events} /></p>
          <div className="mt-3 grid gap-4 md:grid-cols-3">
            <WorkflowForm action={configureControlSwitch} blockUncertainRetry label="Save moderation and retention" confirmation="Moderation events notify staff about new cases; retention clears delivered notices after their history window.">
              <input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="switch" value="inbox_operations" />
              <OnOff name="moderation" label="Moderation events" value={inbox.moderation_events} /><OnOff name="retention" label="Delivery retention" value={inbox.delivery_retention} />
            </WorkflowForm>
            <WorkflowForm action={configureControlSwitch} blockUncertainRetry label="Save job and report events" confirmation="Notifies staff about failed background jobs and new member reports. Existing failures are picked up when turned on.">
              <input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="switch" value="inbox_sources" />
              <OnOff name="jobs" label="Failed job events" value={inbox.job_events} /><OnOff name="reports" label="Report events" value={inbox.report_events} />
            </WorkflowForm>
            <WorkflowForm action={configureControlSwitch} blockUncertainRetry label={inbox.governance_events ? "Turn off governance events" : "Turn on governance events"} confirmation="Notifies the people who must decide on approvals and access reviews.">
              <input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="switch" value="governance_notices" /><input type="hidden" name="enabled" value={String(!inbox.governance_events)} />
            </WorkflowForm>
          </div>
        </li>}
        <Toggle id="access_reviews" title="Access reviews" on={s.access_reviews === true}
          detail="Periodic review of who holds staff access, with recorded keep or remove decisions."
          confirmOn="Lets super admins open and decide access reviews. History is append-only." confirmOff="Blocks new review decisions. History is kept." />
        <Toggle id="invitation_ledger" title="Invitation ledger" on={s.invitation_ledger?.enabled === true}
          detail="Tracks every staff invitation from send to first sign-in, so a lost response can be reconciled."
          confirmOn="New staff invitations are reserved and tracked before the email is sent." confirmOff="Stops tracking new invitations. Pause invitations first if any are in flight."
          blocked={invitationKeyConfigured ? undefined : "Needs ADMIN_INVITATION_HMAC_KEY set on the console before it can be turned on."} />
        <li className="px-5 py-4">
          <div className="flex flex-wrap items-center gap-2"><p className="font-bold text-burgundy">Two-person approvals</p></div>
          <p className="mt-1 text-xs text-ink-muted">Super admin promotions <State on={s.promotion_approvals} /> · broadcasts <State on={s.broadcast_approvals} /> · active super admins {s.active_super_admins}</p>
          <p className="mt-1 text-xs text-ink-muted">These are set at deployment level, not from the console. Broadcast approvals stay off while they only cover immediate broadcasts to everyone.</p>
        </li>
      </ul>
    </Card>
  );
}
