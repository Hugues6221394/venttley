import "server-only";
import { createHmac } from "node:crypto";
import { rpc } from "./audit";
import { uuid } from "./validate";
import { activeStaffRole } from "./staff";
import { createSsrClient } from "./supabase/server";
import { parseInvitationRegister, type InvitationCursor, type InvitationRegister } from "./staff-invitation-model";

// No email, HMAC key or digest is returned to the browser or placed in audit text.
// The stable, dedicated key must be identical on every console instance.
export function prepareInvitation(form: FormData, email: string, username: string, role: string) {
  if (process.env.ADMIN_INVITATION_LEDGER_UI !== "true") return null;
  const key = process.env.ADMIN_INVITATION_HMAC_KEY ?? "";
  if (!/^[0-9a-f]{64}$/i.test(key)) throw new Error("invitation_key_unavailable");
  return {
    p_operation: uuid(form, "operation_id"),
    p_mailbox_hmac: createHmac("sha256", Buffer.from(key, "hex"))
      .update(email.trim().toLowerCase()).digest("hex"),
    p_username: username,
    p_role: role,
  };
}

export async function reserveInvitation(request: NonNullable<ReturnType<typeof prepareInvitation>>): Promise<string> {
  const result = await rpc<{ invitation_id: string; dispatch_allowed: boolean }>("admin_begin_staff_invitation", request);
  // Replaying a successful reservation must NEVER resend provider mail. A lost
  // response is deliberately not retried automatically across Auth/Postgres.
  if (!result || result.dispatch_allowed !== true || !/^[0-9a-f-]{36}$/i.test(result.invitation_id)) {
    throw new Error("invitation_already_attempted");
  }
  return result.invitation_id;
}

export async function recordInvitation(invitation: string, user: string, stage: "provider_accepted" | "access_assigned") {
  await rpc("admin_record_staff_invitation", { p_invitation: invitation, p_user: user, p_stage: stage });
}

export async function completeInvitationGrant(operation: string, invitation: string, reason: string) {
  // Fresh reservation is version 1; its recorded provider response is version 2.
  // Any intervening recovery/cancellation forces inspection instead of granting.
  await rpc("admin_recover_staff_invitation", {
    p_operation: operation, p_invitation: invitation, p_version: 2, p_command: "complete_grant", p_reason: reason,
  });
}

export async function readInvitationRegister(cursor: InvitationCursor): Promise<InvitationRegister | null> {
  if (process.env.ADMIN_INVITATION_LEDGER_UI !== "true") return null;
  try {
    const db = await createSsrClient();
    const { data: { user } } = await db.auth.getUser();
    if (!user || !await activeStaffRole(db, user.id, ["super_admin"])) return null;
    const result = await db.rpc("admin_staff_invitation_register", {
      p_before_at: cursor.beforeAt, p_before_id: cursor.beforeId,
    }).abortSignal(AbortSignal.timeout(6000));
    if (result.error || !result.data) return null;
    return parseInvitationRegister(result.data);
  } catch { return null; }
}
