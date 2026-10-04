"use server";

import { governanceAction, governanceInteger, governanceUtcTime } from "@/lib/governance-action";
import { enumOf, InvalidInput, sha256, uuid } from "@/lib/validate";

export async function scheduleRecoveryDrill(fd: FormData) {
  return governanceAction(["super_admin", "admin"], "admin_create_recovery_drill", () => ({
    p_operation: uuid(fd, "operation_id"),
    p_environment: enumOf(fd, "environment", ["staging", "isolated_restore", "production_recovery_test"] as const),
    p_scheduled_at: governanceUtcTime(fd, "scheduled_at"),
    p_expected_rpo_minutes: governanceInteger(fd, "expected_rpo_minutes", 0, 10080),
    p_expected_rto_minutes: governanceInteger(fd, "expected_rto_minutes", 1, 10080),
  }), "Drill registered. This schedules an internal record; it does not start a restore.");
}

export async function completeRecoveryDrill(fd: FormData) {
  return governanceAction(["super_admin", "admin"], "admin_complete_recovery_drill", () => {
    const passed = governanceInteger(fd, "checks_passed", 0, 100000);
    const total = governanceInteger(fd, "checks_total", 1, 100000);
    if (passed > total) throw new InvalidInput("checks_passed", "cannot exceed checks total");
    return {
      p_operation: uuid(fd, "operation_id"), p_drill: uuid(fd, "drill_id"),
      p_passed: enumOf(fd, "outcome", ["passed", "failed"] as const) === "passed",
      p_actual_rpo_minutes: governanceInteger(fd, "actual_rpo_minutes", 0, 10080),
      p_actual_rto_minutes: governanceInteger(fd, "actual_rto_minutes", 0, 10080),
      p_checks_passed: passed, p_checks_total: total, p_evidence_hash: sha256(fd, "evidence_hash"),
    };
  }, "Results recorded. Independent evidence verification is still required.");
}

export async function verifyRecoveryDrill(fd: FormData) {
  return governanceAction(["super_admin"], "admin_verify_recovery_drill", () => ({
    p_operation: uuid(fd, "operation_id"), p_drill: uuid(fd, "drill_id"),
  }), "Independent evidence review recorded. Verification does not mean the drill passed its targets.");
}
