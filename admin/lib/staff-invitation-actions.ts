"use server";

import { governanceAction, governanceInteger } from "./governance-action";
import { enumOf, uuid } from "./validate";
import type { WorkflowResult } from "./workflow-model";

export async function recoverStaffInvitation(form: FormData): Promise<WorkflowResult> {
  if (process.env.ADMIN_INVITATION_LEDGER_UI !== "true") {
    return { status: "error", message: "Invitation recovery is not enabled." };
  }
  // The pause blocks all new invitation-derived grants, but not investigation
  // or cancellation. Independent role changes retain their existing authority.
  if (process.env.ADMIN_STAFF_INVITES_DISABLED === "true" && form.get("command") === "complete_grant") {
    return { status: "error", message: "New invitation grants are paused. Reconciliation and cancellation remain available." };
  }
  return governanceAction(["super_admin"], "admin_recover_staff_invitation", () => ({
    p_operation: uuid(form, "operation_id"),
    p_invitation: uuid(form, "invitation_id"),
    p_version: governanceInteger(form, "version", 1, 999999),
    p_command: enumOf(form, "command", ["reconcile", "cancel", "complete_grant"] as const),
  }), "Invitation operation recorded. Refresh to inspect the current state. No email was sent and no Auth link was revoked.");
}

export async function repairStaffInvitationSetup(form: FormData): Promise<WorkflowResult> {
  if (process.env.ADMIN_INVITATION_LEDGER_UI !== "true" || process.env.ADMIN_INVITATION_SETUP_REPAIR_UI !== "true") {
    return { status: "error", message: "Invitation setup repair is not enabled." };
  }
  if (process.env.ADMIN_STAFF_INVITES_DISABLED === "true") {
    return { status: "error", message: "Invitation setup repairs are paused. Investigation and cancellation remain available." };
  }
  return governanceAction(["super_admin"], "admin_repair_staff_invitation_setup", () => ({
    p_operation: uuid(form, "operation_id"),
    p_invitation: uuid(form, "invitation_id"),
    p_version: governanceInteger(form, "version", 1, 999999),
  }), "Missing setup marker repaired. Refresh the invitation before separately completing its requested role grant. No password changed, email sent, link revoked or access granted.");
}
