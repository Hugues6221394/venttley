"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { rpc } from "@/lib/audit";
import { operationalResult, requireOperationalActor } from "@/lib/operational-actions";
import { enumOf, optUuid, uuid } from "@/lib/validate";

const ROLES = ["super_admin", "admin", "support"] as const;

function finish(result: string): never {
  revalidatePath("/support/cases");
  redirect(`/support/cases?result=${encodeURIComponent(result)}`);
}

export async function createSupportCase(formData: FormData) {
  let result = "case_created";
  try {
    await requireOperationalActor(ROLES);
    await rpc("admin_create_support_case", {
      p_operation: uuid(formData, "operation_id"),
      p_source_kind: enumOf(formData, "source_kind", ["appeal", "verification", "privacy", "account", "recovery", "safety", "other"] as const),
      p_source_id: optUuid(formData, "source_id"),
      p_member: optUuid(formData, "member_id"),
      p_category: enumOf(formData, "category", ["access", "appeal_help", "verification_help", "privacy_request", "recovery_help", "safety_followup", "technical", "other"] as const),
      p_priority: enumOf(formData, "priority", ["low", "normal", "high", "critical"] as const),
    });
  } catch (error) { result = operationalResult(error); }
  finish(result);
}

export async function updateSupportCase(formData: FormData) {
  let result = "case_updated";
  try {
    await requireOperationalActor(ROLES);
    await rpc("admin_update_support_case", {
      p_operation: uuid(formData, "operation_id"),
      p_case: uuid(formData, "case_id"),
      p_status: enumOf(formData, "status", ["open", "assigned", "waiting_member", "waiting_internal", "resolved", "closed"] as const),
      p_priority: enumOf(formData, "priority", ["low", "normal", "high", "critical"] as const),
      p_assignee: optUuid(formData, "assignee_id"),
    });
  } catch (error) { result = operationalResult(error); }
  finish(result);
}
