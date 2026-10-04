import { InvalidInput } from "./validate";
import type { WorkflowResult } from "./workflow-model";

const messages = {
  invited: "Auth accepted the invitation request and staff access was assigned. This does not confirm email delivery.",
  access_granted: "Staff access granted. Refresh to inspect current access.",
  role_changed: "Staff role changed and existing sessions revoked.",
  status_changed: "Staff account status changed and existing sessions revoked.",
  access_removed: "Staff access removed. The member account and audit history were preserved.",
} as const;
export type StaffSuccess = keyof typeof messages;
export function staffSuccess(code: StaffSuccess): WorkflowResult {
  return { status: "success", message: messages[code] };
}

export function staffFailure(error: unknown, mutationStarted: boolean): WorkflowResult {
  if (error instanceof Error && error.message === "admin_set_user_role: promotion_approval_required") {
    return {status:"error",message:"Super-admin promotion requires independent approval. Open Sensitive approvals to request and execute it. This role-change transaction was refused."};
  }
  // Auth and Postgres are separate systems. Even a specific refusal in a later
  // step must not imply that the earlier invitation/account was never created.
  if (mutationStarted) return { status: "unknown", message: "The result could not be confirmed. An account, invitation or access change may already exist. Inputs are retained, but resubmission is disabled. Inspect the current account and audit trail before starting a new operation." };
  if (error instanceof InvalidInput) {
    const field = error.message.split(":", 1)[0];
    return { status: "error", message: "Check the indicated field. No staff mutation was started.",
      ...(["email", "pseudonym", "user_id", "role", "status", "reason", "confirm"].includes(field) ? {field} : {}) };
  }
  const code = error instanceof Error ? error.message : "";
  const known: Record<string, {message:string; field?:string}> = {
    mfa_required: {message:"Complete MFA in a separate tab, then retry. Your inputs are retained."},
    not_authenticated: {message:"Your session is unavailable. Sign in again before changing access."},
    not_authorized: {message:"Your current staff access cannot perform this action."},
    self_change: {message:"Another super admin must change your access. Self-changes are blocked.",field:"user_id"},
    last_super_admin: {message:"The last active super admin cannot be demoted or removed."},
    last_super_admin_check_failed: {message:"The super-admin safety check is unavailable. No staff mutation was started."},
    handle_taken: {message:"That permanent handle is already in use. Choose another; no invitation was requested.",field:"pseudonym"},
    confirm_required: {message:"Type REMOVE to confirm removal of staff access.",field:"confirm"},
    invite_redirect_required: {message:"Staff invitations are not configured. Ask the deployment owner to check the invitation redirect."},
    invite_redirect_invalid: {message:"The invitation redirect configuration is invalid. No invitation was requested."},
    invitation_key_unavailable: {message:"Invitation tracking is not configured correctly. Ask the deployment owner to check its dedicated key. No invitation was requested."},
    invitations_paused: {message:"New staff invitations are paused. No invitation was requested."},
  };
  if (Object.hasOwn(known,code)) return {status:"error",...known[code]};
  return {status:"error",message:"The preflight checks could not be completed. No staff mutation was started. Try again after checking service availability."};
}
