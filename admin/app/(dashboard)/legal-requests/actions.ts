"use server";

import { governanceAction, governanceUtcTime } from "@/lib/governance-action";
import { enumOf, InvalidInput, optStr, reqStr, sha256, uuid } from "@/lib/validate";

export async function createLegalRequest(fd: FormData) {
  return governanceAction(["super_admin", "admin"], "admin_create_legal_request", () => {
    const due = governanceUtcTime(fd, "due_at");
    if (Date.parse(due) <= Date.now()) throw new InvalidInput("due_at", "must be in the future");
    const jurisdiction = reqStr(fd, "jurisdiction", 16).toUpperCase();
    if (!/^[A-Z][A-Z0-9_-]{1,15}$/.test(jurisdiction)) throw new InvalidInput("jurisdiction", "use a jurisdiction code");
    return {
      p_operation: uuid(fd, "operation_id"),
      p_request_type: enumOf(fd, "request_type", ["law_enforcement", "court_order", "preservation", "privacy_regulator", "emergency", "other"] as const),
      p_jurisdiction: jurisdiction, p_reference_hash: sha256(fd, "reference_hash"),
      p_scope_code: enumOf(fd, "scope_code", ["account_metadata", "content_preservation", "account_disclosure", "platform_statistics", "emergency_request"] as const),
      p_due_at: due,
    };
  }, "Request registered. Independent approval is still required; no content was disclosed.");
}

export async function decideLegalRequest(fd: FormData) {
  return governanceAction(["super_admin"], "admin_decide_legal_request", () => {
    const approve = enumOf(fd, "decision", ["approve", "reject"] as const) === "approve";
    const rawManifest = optStr(fd, "manifest_hash", 64);
    const manifest = rawManifest ? sha256(fd, "manifest_hash") : null;
    const verified = fd.get("requester_verified") === "on";
    const reason = enumOf(fd, "reason_code", ["valid_authority", "invalid_authority", "insufficient_scope", "emergency_authority", "withdrawn"] as const);
    if (approve && !manifest) throw new InvalidInput("manifest_hash", "required for approval");
    if (approve && !verified) throw new InvalidInput("requester_verified", "required for approval");
    if (approve && !["valid_authority", "emergency_authority"].includes(reason)) throw new InvalidInput("reason_code", "must support approval");
    return {
      p_operation: uuid(fd, "operation_id"), p_request: uuid(fd, "request_id"),
      p_approve: approve, p_requester_verified: verified, p_reason_code: reason, p_manifest_hash: manifest,
    };
  }, "Decision recorded. This action does not package or transmit any disclosure.");
}

export async function fulfilLegalRequest(fd: FormData) {
  return governanceAction(["super_admin"], "admin_mark_legal_request_fulfilled", () => ({
    p_operation: uuid(fd, "operation_id"), p_request: uuid(fd, "request_id"), p_receipt_hash: sha256(fd, "receipt_hash"),
  }), "Completion receipt recorded. No external transmission was performed by this action.");
}
