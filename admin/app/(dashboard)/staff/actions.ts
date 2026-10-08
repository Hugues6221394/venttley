"use server";

import { revalidatePath } from "next/cache";
import { staffFailure, staffSuccess, type StaffSuccess } from "@/lib/staff-action-result";
import { rpc } from "@/lib/audit";
import { limitAction } from "@/lib/guard";
import { activeStaffRole } from "@/lib/staff";
import { prepareInvitation, reserveInvitation, recordInvitation, completeInvitationGrant } from "@/lib/staff-invitation-ledger";
import {
  createAdminClient,
  createRequiredAuthAdminClient,
  createSsrClient,
} from "@/lib/supabase/server";
import {
  emailAddress,
  enumOf,
  pseudonym,
  reqStr,
  uuid,
} from "@/lib/validate";

const ASSIGNABLE_STAFF_ROLES = [
  "super_admin",
  "admin",
  "moderator",
  "support",
  "analyst",
  "read_only_auditor",
] as const;

const INVITABLE_STAFF_ROLES = [
  "admin",
  "moderator",
  "support",
  "analyst",
  "read_only_auditor",
] as const;

type Gate = { actorId: string };

async function requireSuperAdminAal2(): Promise<Gate> {
  const ssr = await createSsrClient();
  const {
    data: { user },
  } = await ssr.auth.getUser();
  if (!user) throw new Error("not_authenticated");

  const role = await activeStaffRole(ssr, user.id, ["super_admin"]);
  if (role !== "super_admin") throw new Error("not_authorized");

  const { data: aal, error } =
    await ssr.auth.mfa.getAuthenticatorAssuranceLevel();
  if (error || aal?.currentLevel !== "aal2") throw new Error("mfa_required");
  return { actorId: user.id };
}

function finish(code: StaffSuccess) {
  revalidatePath("/staff");
  revalidatePath("/staff/invitations");
  revalidatePath("/staff/access-reviews");
  revalidatePath("/roles");
  return staffSuccess(code);
}

async function protectLastSuperAdmin(
  targetId: string,
  nextRole: string,
): Promise<void> {
  const db = await createAdminClient();
  const { data: target, error: targetError } = await db
    .from("users")
    .select("user_role")
    .eq("user_id", targetId)
    .maybeSingle();
  if (targetError || !target) throw new Error("invalid_target");
  if (target.user_role !== "super_admin" || nextRole === "super_admin") return;

  const { count, error } = await db
    .from("users")
    .select("user_id", { count: "exact", head: true })
    .eq("user_role", "super_admin")
    .eq("account_status", "active")
    .is("deactivated_at", null);
  if (error) throw new Error("last_super_admin_check_failed");
  if ((count ?? 0) <= 1) throw new Error("last_super_admin");
}

export async function inviteStaff(formData: FormData) {
  let mutationStarted = false;
  try {
    await limitAction("destructive");
    await requireSuperAdminAal2();
    if (process.env.ADMIN_STAFF_INVITES_DISABLED === "true") throw new Error("invitations_paused");
    const email = emailAddress(formData, "email");
    // A second super admin must be an explicit promotion of an already
    // accepted, MFA-capable account. Email possession alone is not enough for
    // the most powerful role in the system.
    const role = enumOf(formData, "role", INVITABLE_STAFF_ROLES);
    const reason = reqStr(formData, "reason", 500);
    // Chosen by the inviter, not generated. This used to be
    // `staff_${randomBytes(8).toString("hex")}`, which is permanent the moment
    // the row exists — guard_user_identity refuses every later change — so a
    // staff member was stuck forever with a name nobody could read, and the
    // audit log recorded their actions under it. The handle is still a
    // pseudonym: it names a role, not a person.
    const handle = pseudonym(formData, "pseudonym");

    // The unique index on lower(anonymous_pseudonym) is the real guarantee;
    // this lookup only buys a usable error. Without it a collision surfaces as
    // a Postgres uniqueness violation *after* inviteUserByEmail has already
    // created the Auth account and sent the mail, leaving a half-built account
    // and an invitation nobody can accept.
    const admin = await createAdminClient();
    const { data: existing, error: lookupError } = await admin
      .from("users")
      .select("user_id")
      .eq("username_normalized", handle.toLowerCase())
      .maybeSingle();
    if (lookupError) throw new Error("handle_lookup_failed");
    if (existing) throw new Error("handle_taken");

    const redirectTo = process.env.ADMIN_INVITE_REDIRECT_URL?.trim();
    if (!redirectTo) throw new Error("invite_redirect_required");
    const parsed = new URL(redirectTo);
    if (parsed.protocol !== "https:" && parsed.hostname !== "localhost") {
      throw new Error("invite_redirect_invalid");
    }
    if (parsed.pathname !== "/" || parsed.search || parsed.hash) {
      throw new Error("invite_redirect_invalid");
    }

    const authAdmin = createRequiredAuthAdminClient();
    const invitationRequest = prepareInvitation(formData, email, handle, role);
    mutationStarted = true;
    const invitationId = invitationRequest ? await reserveInvitation(invitationRequest) : null;
    const { data, error } = await authAdmin.auth.admin.inviteUserByEmail(email, {
      redirectTo,
      data: {
        pseudonym: handle,
        avatar_seed: "rose-orb-0001",
      },
    });
    if (error || !data.user) {
      throw new Error(error?.message ?? "invite_failed");
    }
    if (invitationId) await recordInvitation(invitationId, data.user.id, "provider_accepted");

    const { error: metadataError } =
      await authAdmin.auth.admin.updateUserById(data.user.id, {
        app_metadata: {
          ...data.user.app_metadata,
          staff_invite_pending: true,
        },
      });
    if (metadataError) throw new Error("invite_state_failed");

    // The auth.users insert synchronously creates public.users. Role assignment
    // then goes through the caller-bound RPC so authorization, AAL2, session
    // revocation and audit remain database-enforced. If this response is lost,
    // the account is either still harmless `normal` or already has the intended
    // audited role; we deliberately do not issue an ambiguous compensating
    // delete across the Auth and Postgres systems.
    if (invitationId && invitationRequest) {
      await completeInvitationGrant(invitationRequest.p_operation, invitationId, reason);
    } else {
      await rpc("admin_set_user_role", {
        p_target: data.user.id,
        p_role: role,
        p_reason: `Staff invitation: ${reason}`,
      });
    }
  } catch (error) {
    return staffFailure(error, mutationStarted);
  }
  return finish("invited");
}

function inviteRedirect(): string {
  const redirectTo = process.env.ADMIN_INVITE_REDIRECT_URL?.trim();
  if (!redirectTo) throw new Error("invite_redirect_required");
  const parsed = new URL(redirectTo);
  if (parsed.protocol !== "https:" && parsed.hostname !== "localhost") throw new Error("invite_redirect_invalid");
  if (parsed.pathname !== "/" || parsed.search || parsed.hash) throw new Error("invite_redirect_invalid");
  return redirectTo;
}

/** An account still waiting for its invitation to be finished, or why not. */
async function pendingInvite(targetId: string) {
  const authAdmin = createRequiredAuthAdminClient();
  const { data, error } = await authAdmin.auth.admin.getUserById(targetId);
  if (error || !data.user) throw new Error("invalid_target");
  if (data.user.app_metadata?.staff_invite_pending !== true) throw new Error("invitation_not_pending");
  return { authAdmin, user: data.user };
}

export async function resendStaffInvite(formData: FormData) {
  let mutationStarted = false;
  try {
    await limitAction("destructive");
    await requireSuperAdminAal2();
    if (process.env.ADMIN_STAFF_INVITES_DISABLED === "true") throw new Error("invitations_paused");
    const targetId = uuid(formData, "user_id");
    const reason = reqStr(formData, "reason", 500);
    const redirectTo = inviteRedirect();
    const { authAdmin, user } = await pendingInvite(targetId);
    // Auth only re-sends to an address that has not opened its invitation.
    if (user.email_confirmed_at || !user.email) throw new Error("invitation_already_opened");
    await rpc("admin_note_staff_invitation", { p_target: targetId, p_action: "resent", p_reason: reason });
    mutationStarted = true;
    const { error } = await authAdmin.auth.admin.inviteUserByEmail(user.email, { redirectTo });
    if (error) throw new Error(error.message);
  } catch (error) {
    return staffFailure(error, mutationStarted);
  }
  return finish("invite_resent");
}

export async function revokeStaffInvite(formData: FormData) {
  let mutationStarted = false;
  try {
    await limitAction("destructive");
    const { actorId } = await requireSuperAdminAal2();
    const targetId = uuid(formData, "user_id");
    if (targetId === actorId) throw new Error("self_change");
    const reason = reqStr(formData, "reason", 500);
    const { authAdmin } = await pendingInvite(targetId);
    await protectLastSuperAdmin(targetId, "normal");
    mutationStarted = true;
    // Access first, through the audited path that also revokes sessions; then
    // the record; then the account. If deletion fails, what is left is a
    // member account with no staff access and no usable password.
    await rpc("admin_set_user_role", { p_target: targetId, p_role: "normal", p_reason: `Invitation revoked: ${reason}` });
    await rpc("admin_note_staff_invitation", { p_target: targetId, p_action: "revoked", p_reason: reason });
    const { error } = await authAdmin.auth.admin.deleteUser(targetId);
    if (error) throw new Error("invite_delete_failed");
  } catch (error) {
    return staffFailure(error, mutationStarted);
  }
  return finish("invite_revoked");
}

export async function grantExistingStaff(formData: FormData) {
  let mutationStarted = false;
  try {
    await limitAction("destructive");
    const { actorId } = await requireSuperAdminAal2();
    const targetId = uuid(formData, "user_id");
    if (targetId === actorId) throw new Error("self_change");
    const role = enumOf(formData, "role", ASSIGNABLE_STAFF_ROLES);
    const reason = reqStr(formData, "reason", 500);
    mutationStarted = true;
    await rpc("admin_set_user_role", {
      p_target: targetId,
      p_role: role,
      p_reason: reason,
    });
  } catch (error) {
    return staffFailure(error, mutationStarted);
  }
  return finish("access_granted");
}

export async function changeStaffRole(formData: FormData) {
  let mutationStarted = false;
  try {
    await limitAction("destructive");
    const { actorId } = await requireSuperAdminAal2();
    const targetId = uuid(formData, "user_id");
    const nextRole = enumOf(formData, "role", ASSIGNABLE_STAFF_ROLES);
    if (targetId === actorId) throw new Error("self_change");
    await protectLastSuperAdmin(targetId, nextRole);
    const reason = reqStr(formData, "reason", 500);
    mutationStarted = true;
    await rpc("admin_set_user_role", {
      p_target: targetId,
      p_role: nextRole,
      p_reason: reason,
    });
  } catch (error) {
    return staffFailure(error, mutationStarted);
  }
  return finish("role_changed");
}

export async function setStaffStatus(formData: FormData) {
  let mutationStarted = false;
  try {
    await limitAction("destructive");
    const { actorId } = await requireSuperAdminAal2();
    const targetId = uuid(formData, "user_id");
    if (targetId === actorId) throw new Error("self_change");
    const status = enumOf(formData, "status", ["active", "suspended"] as const);
    const reason = reqStr(formData, "reason", 500);
    mutationStarted = true;
    await rpc("admin_set_user_status", {
      p_target: targetId,
      p_status: status,
      p_reason: reason,
    });
  } catch (error) {
    return staffFailure(error, mutationStarted);
  }
  return finish("status_changed");
}

export async function removeStaffAccess(formData: FormData) {
  let mutationStarted = false;
  try {
    await limitAction("destructive");
    const { actorId } = await requireSuperAdminAal2();
    const targetId = uuid(formData, "user_id");
    if (targetId === actorId) throw new Error("self_change");
    if (reqStr(formData, "confirm", 20) !== "REMOVE") {
      throw new Error("confirm_required");
    }
    await protectLastSuperAdmin(targetId, "normal");
    const reason = reqStr(formData, "reason", 500);
    mutationStarted = true;
    await rpc("admin_set_user_role", {
      p_target: targetId,
      p_role: "normal",
      p_reason: reason,
    });
  } catch (error) {
    return staffFailure(error, mutationStarted);
  }
  return finish("access_removed");
}
