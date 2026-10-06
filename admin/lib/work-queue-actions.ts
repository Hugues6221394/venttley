"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { rpc } from "@/lib/audit";
import { operationalResult, requireOperationalActor } from "@/lib/operational-actions";
import { getRenderStaff } from "@/lib/supabase/server";
import { enumOf, uuid } from "@/lib/validate";
import { parseKind, parseView } from "@/lib/work-queue";

const CASE_ROLES = ["super_admin", "admin", "moderator"] as const;
const SUPPORT_ROLES = ["super_admin", "admin", "support"] as const;
const SUPPORT_STATUSES = ["open", "assigned", "waiting_member", "waiting_internal"] as const;
const PRIORITIES = ["low", "normal", "high", "critical"] as const;

function back(form: FormData, result: string): never {
  const sp = new URLSearchParams();
  const view = parseView(String(form.get("view") ?? ""));
  const kind = parseKind(String(form.get("kind_filter") ?? ""));
  if (view !== "all") sp.set("view", view);
  if (kind !== "all") sp.set("kind", kind);
  sp.set("result", result);
  revalidatePath("/queue");
  redirect(`/queue?${sp.toString()}`);
}

function failure(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes("already_claimed")) return "already_claimed";
  if (message.includes("assignee is not a moderator")) return "invalid_assignee";
  if (message.includes("request_not_open") || message.includes("closed_support_case")) return "no_longer_open";
  return operationalResult(error);
}

async function me(): Promise<string> {
  const staff = await getRenderStaff();
  if (!staff) throw new Error("not_authorized");
  return staff.userId;
}

async function updateSupport(form: FormData, assignee: string | null) {
  await requireOperationalActor(SUPPORT_ROLES);
  const current = enumOf(form, "status", SUPPORT_STATUSES);
  const status = assignee ? (current === "open" ? "assigned" : current) : (current === "assigned" ? "open" : current);
  await rpc("admin_update_support_case", {
    p_operation: randomUUID(),
    p_case: uuid(form, "id"),
    p_status: status,
    p_priority: enumOf(form, "priority", PRIORITIES),
    p_assignee: assignee,
  });
}

export async function claimWorkItem(form: FormData) {
  let result = "claimed";
  try {
    const kind = parseKind(String(form.get("item_kind") ?? ""));
    if (kind === "case") {
      await requireOperationalActor(CASE_ROLES);
      await rpc("admin_assign_case", { p_case: uuid(form, "id"), p_assignee: await me(), p_reason: "claimed from the work queue" });
    } else if (kind === "verification") {
      await requireOperationalActor(["super_admin"]);
      await rpc("admin_claim_verification", { p_request: uuid(form, "id") });
    } else if (kind === "support") {
      await updateSupport(form, await me());
    } else {
      result = "invalid_input";
    }
  } catch (error) { result = failure(error); }
  back(form, result);
}

export async function releaseWorkItem(form: FormData) {
  let result = "released";
  try {
    const kind = parseKind(String(form.get("item_kind") ?? ""));
    if (kind === "case") {
      await requireOperationalActor(CASE_ROLES);
      await rpc("admin_assign_case", { p_case: uuid(form, "id"), p_assignee: null, p_reason: "released from the work queue" });
    } else if (kind === "support") {
      await updateSupport(form, null);
    } else {
      result = "invalid_input";
    }
  } catch (error) { result = failure(error); }
  back(form, result);
}

export async function assignWorkItem(form: FormData) {
  let result = "assigned";
  try {
    const kind = parseKind(String(form.get("item_kind") ?? ""));
    const assignee = uuid(form, "assignee_id");
    if (kind === "case") {
      await requireOperationalActor(CASE_ROLES);
      await rpc("admin_assign_case", { p_case: uuid(form, "id"), p_assignee: assignee, p_reason: "assigned from the work queue" });
    } else if (kind === "support") {
      await updateSupport(form, assignee);
    } else {
      result = "invalid_input";
    }
  } catch (error) { result = failure(error); }
  back(form, result);
}
