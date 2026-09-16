"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { rpc } from "@/lib/audit";
import { operationalResult, requireOperationalActor } from "@/lib/operational-actions";
import { enumOf, optStr, optTimestamp, reqStr, sha256, uuid } from "@/lib/validate";

function finish(result: string): never {
  revalidatePath("/legal-requests");
  redirect(`/legal-requests?result=${encodeURIComponent(result)}`);
}

export async function createLegalRequest(formData: FormData) {
  let result = "request_registered";
  try {
    await requireOperationalActor(["super_admin", "admin"]);
    const dueAt = optTimestamp(formData, "due_at");
    if (!dueAt) throw new Error("due_at_required");
    await rpc("admin_create_legal_request", {
      p_operation: uuid(formData, "operation_id"),
      p_request_type: enumOf(formData, "request_type", ["law_enforcement", "court_order", "preservation", "privacy_regulator", "emergency", "other"] as const),
      p_jurisdiction: reqStr(formData, "jurisdiction", 16).toUpperCase(),
      p_reference_hash: sha256(formData, "reference_hash"),
      p_scope_code: enumOf(formData, "scope_code", ["account_metadata", "content_preservation", "account_disclosure", "platform_statistics", "emergency_request"] as const),
      p_due_at: dueAt,
    });
  } catch (error) { result = operationalResult(error); }
  finish(result);
}

export async function decideLegalRequest(formData: FormData) {
  let result = "decision_recorded";
  try {
    await requireOperationalActor(["super_admin"]);
    const decision = enumOf(formData, "decision", ["approve", "reject"] as const);
    const rawManifest = optStr(formData, "manifest_hash", 64);
    if (rawManifest && !/^[0-9a-f]{64}$/i.test(rawManifest)) throw new Error("invalid_manifest_hash");
    await rpc("admin_decide_legal_request", {
      p_operation: uuid(formData, "operation_id"),
      p_request: uuid(formData, "request_id"),
      p_approve: decision === "approve",
      p_requester_verified: formData.get("requester_verified") === "on",
      p_reason_code: enumOf(formData, "reason_code", ["valid_authority", "invalid_authority", "insufficient_scope", "emergency_authority", "withdrawn"] as const),
      p_manifest_hash: rawManifest?.toLowerCase() ?? null,
    });
  } catch (error) { result = operationalResult(error); }
  finish(result);
}

export async function fulfilLegalRequest(formData: FormData) {
  let result = "fulfilment_recorded";
  try {
    await requireOperationalActor(["super_admin"]);
    await rpc("admin_mark_legal_request_fulfilled", {
      p_operation: uuid(formData, "operation_id"),
      p_request: uuid(formData, "request_id"),
      p_receipt_hash: sha256(formData, "receipt_hash"),
    });
  } catch (error) { result = operationalResult(error); }
  finish(result);
}
