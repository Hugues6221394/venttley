"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { rpc } from "@/lib/audit";
import { limitAction } from "@/lib/guard";
import { activeStaffRole } from "@/lib/staff";
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

function resultCode(error: unknown): string {
  const message = error instanceof Error ? error.message.toLowerCase() : "";
  if (message.includes("mfa") || message.includes("aal2")) return "mfa_required";
  if (message.includes("not_authorized") || message.includes("forbidden")) return "forbidden";
  if (message.includes("already") || message.includes("registered") || message.includes("exists")) return "already_exists";
  if (message.includes("handle_taken")) return "handle_taken";
  if (message.includes("last_super_admin")) return "last_super_admin";
  if (message.includes("self_change")) return "self_change";
  if (message.includes("email") || message.includes("required") || message.includes("must be")) return "invalid_input";
  return "failed";
}

function finish(code: string): never {
  revalidatePath("/staff");
  revalidatePath("/roles");
  redirect(`/staff?result=${encodeURIComponent(code)}`);
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
  let result = "invited";
  try {
    await limitAction("destructive");
    await requireSuperAdminAal2();
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
    await rpc("admin_set_user_role", {
      p_target: data.user.id,
      p_role: role,
      p_reason: `Staff invitation: ${reason}`,
    });
  } catch (error) {
    result = resultCode(error);
  }
  finish(result);
}

export async function grantExistingStaff(formData: FormData) {
  let result = "access_granted";
  try {
    await limitAction("destructive");
    const { actorId } = await requireSuperAdminAal2();
    const targetId = uuid(formData, "user_id");
    if (targetId === actorId) throw new Error("self_change");
    await rpc("admin_set_user_role", {
      p_target: targetId,
      p_role: enumOf(formData, "role", ASSIGNABLE_STAFF_ROLES),
      p_reason: reqStr(formData, "reason", 500),
    });
  } catch (error) {
    result = resultCode(error);
  }
  finish(result);
}

export async function changeStaffRole(formData: FormData) {
  let result = "role_changed";
  try {
    await limitAction("destructive");
    const { actorId } = await requireSuperAdminAal2();
    const targetId = uuid(formData, "user_id");
    const nextRole = enumOf(formData, "role", ASSIGNABLE_STAFF_ROLES);
    if (targetId === actorId) throw new Error("self_change");
    await protectLastSuperAdmin(targetId, nextRole);
    await rpc("admin_set_user_role", {
      p_target: targetId,
      p_role: nextRole,
      p_reason: reqStr(formData, "reason", 500),
    });
  } catch (error) {
    result = resultCode(error);
  }
  finish(result);
}

export async function setStaffStatus(formData: FormData) {
  let result = "status_changed";
  try {
    await limitAction("destructive");
    const { actorId } = await requireSuperAdminAal2();
    const targetId = uuid(formData, "user_id");
    if (targetId === actorId) throw new Error("self_change");
    await rpc("admin_set_user_status", {
      p_target: targetId,
      p_status: enumOf(formData, "status", ["active", "suspended"] as const),
      p_reason: reqStr(formData, "reason", 500),
    });
  } catch (error) {
    result = resultCode(error);
  }
  finish(result);
}

export async function removeStaffAccess(formData: FormData) {
  let result = "access_removed";
  try {
    await limitAction("destructive");
    const { actorId } = await requireSuperAdminAal2();
    const targetId = uuid(formData, "user_id");
    if (targetId === actorId) throw new Error("self_change");
    if (reqStr(formData, "confirm", 20) !== "REMOVE") {
      throw new Error("confirm_required");
    }
    await protectLastSuperAdmin(targetId, "normal");
    await rpc("admin_set_user_role", {
      p_target: targetId,
      p_role: "normal",
      p_reason: reqStr(formData, "reason", 500),
    });
  } catch (error) {
    result = resultCode(error);
  }
  finish(result);
}
