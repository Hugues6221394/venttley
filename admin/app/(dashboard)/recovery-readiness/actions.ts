"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { rpc } from "@/lib/audit";
import { operationalResult, requireOperationalActor } from "@/lib/operational-actions";
import { enumOf, intInRange, optTimestamp, sha256, uuid } from "@/lib/validate";

function finish(result: string): never {
  revalidatePath("/recovery-readiness");
  redirect(`/recovery-readiness?result=${encodeURIComponent(result)}`);
}

export async function scheduleRecoveryDrill(formData: FormData) {
  let result = "drill_scheduled";
  try {
    await requireOperationalActor(["super_admin", "admin"]);
    const scheduledAt = optTimestamp(formData, "scheduled_at");
    if (!scheduledAt) throw new Error("scheduled_at_required");
    await rpc("admin_create_recovery_drill", {
      p_operation: uuid(formData, "operation_id"),
      p_environment: enumOf(formData, "environment", ["staging", "isolated_restore", "production_recovery_test"] as const),
      p_scheduled_at: scheduledAt,
      p_expected_rpo_minutes: intInRange(formData, "expected_rpo_minutes", 0, 10080),
      p_expected_rto_minutes: intInRange(formData, "expected_rto_minutes", 1, 10080),
    });
  } catch (error) { result = operationalResult(error); }
  finish(result);
}

export async function completeRecoveryDrill(formData: FormData) {
  let result = "results_recorded";
  try {
    await requireOperationalActor(["super_admin", "admin"]);
    await rpc("admin_complete_recovery_drill", {
      p_operation: uuid(formData, "operation_id"),
      p_drill: uuid(formData, "drill_id"),
      p_passed: enumOf(formData, "outcome", ["passed", "failed"] as const) === "passed",
      p_actual_rpo_minutes: intInRange(formData, "actual_rpo_minutes", 0, 10080),
      p_actual_rto_minutes: intInRange(formData, "actual_rto_minutes", 0, 10080),
      p_checks_passed: intInRange(formData, "checks_passed", 0, 100000),
      p_checks_total: intInRange(formData, "checks_total", 1, 100000),
      p_evidence_hash: sha256(formData, "evidence_hash"),
    });
  } catch (error) { result = operationalResult(error); }
  finish(result);
}

export async function verifyRecoveryDrill(formData: FormData) {
  let result = "drill_verified";
  try {
    await requireOperationalActor(["super_admin"]);
    await rpc("admin_verify_recovery_drill", {
      p_operation: uuid(formData, "operation_id"),
      p_drill: uuid(formData, "drill_id"),
    });
  } catch (error) { result = operationalResult(error); }
  finish(result);
}
