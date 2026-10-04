import "server-only";

import { rpc } from "./audit";
import { requireOperationalActor } from "./operational-actions";
import { createSsrClient } from "./supabase/server";
import { InvalidInput, intInRange, reqStr } from "./validate";
import { workflowFailure, type WorkflowResult } from "./workflow-model";

// These datetime-local controls are explicitly labelled UTC. Deployment host
// timezone must never determine a legal deadline or a scheduled drill.
export function governanceUtcTime(fd: FormData, field: string): string {
  const value = reqStr(fd, field, 16);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value)) throw new InvalidInput(field, "use a UTC date and time");
  const date = new Date(`${value}:00.000Z`);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 16) !== value) {
    throw new InvalidInput(field, "use a valid UTC date and time");
  }
  return date.toISOString();
}

export function governanceInteger(fd: FormData, field: string, min: number, max: number): number {
  // Number('') is zero: absent evidence must not become a measured zero.
  if (!/^\d+$/.test(reqStr(fd, field, 6))) throw new InvalidInput(field, "enter a whole number");
  return intInRange(fd, field, min, max);
}

type GovernanceRpc = "admin_create_recovery_drill" | "admin_complete_recovery_drill" | "admin_verify_recovery_drill"
  | "admin_create_legal_request" | "admin_decide_legal_request" | "admin_mark_legal_request_fulfilled"
  | "admin_create_access_review" | "admin_access_review_command" | "admin_recover_staff_invitation"
  | "admin_repair_staff_invitation_setup"
  | "admin_request_staff_promotion" | "admin_staff_promotion_command"
  | "admin_request_broadcast_approval" | "admin_broadcast_approval_command" | "admin_stop_approved_broadcast";
const fields = new Set(["scheduled_at", "environment", "expected_rpo_minutes", "expected_rto_minutes", "outcome",
  "actual_rpo_minutes", "actual_rto_minutes", "checks_passed", "checks_total", "evidence_hash", "due_at",
  "request_type", "jurisdiction", "reference_hash", "scope_code", "decision", "manifest_hash", "requester_verified",
  "reason_code", "receipt_hash", "period", "valid_until", "reviewer_id", "target_id", "title", "body", "urgency", "expires_at"]);

export async function governanceAction(roles: readonly string[], fn: GovernanceRpc,
  parameters: () => Record<string, unknown>, message: string): Promise<WorkflowResult> {
  let started = false;
  try {
    await requireOperationalActor(roles);
    const db = await createSsrClient();
    const { data, error } = await db.auth.mfa.getAuthenticatorAssuranceLevel();
    if (error || data?.currentLevel !== "aal2") return workflowFailure("mfa_required");
    const params = parameters();
    started = true;
    await rpc(fn, params);
    // No eager revalidation: keep the confirmed result mounted until explicit
    // record refresh. These routes are force-dynamic.
    return { status: "success", message };
  } catch (error) {
    if (!started && error instanceof InvalidInput) {
      const field = error.message.split(":", 1)[0];
      return workflowFailure("invalid_input", fields.has(field) ? field : undefined);
    }
    const raw = error instanceof Error ? error.message : "";
    // Exact transactional refusals only. An unfamiliar or transport error can
    // follow a committed write; never classify it by matching a substring.
    const code = started && raw.startsWith(`${fn}: `) ? raw.slice(fn.length + 2) : !started ? raw : "";
    const refusals: Record<string, string> = {
      not_authorized: "forbidden", mfa_required: "mfa_required", aal2_required: "mfa_required",
      "aal2_required: this action requires a completed MFA step-up, not just a signed-in session": "mfa_required",
      rate_limited: "rate_limited", idempotency_payload_mismatch: "retry_mismatch",
      independent_verifier_required: "independent_operator_required", independent_approver_required: "independent_operator_required",
      recovery_drill_not_found: "not_found", legal_request_not_found: "not_found",
      recovery_drill_not_completable: "conflict", recovery_evidence_not_ready: "conflict",
      legal_request_already_decided: "conflict", legal_request_not_approved: "conflict",
      not_found: "not_found", access_reviews_disabled: "forbidden", reviewer_not_assigned: "forbidden",
      independent_reviewer_required: "independent_operator_required", review_conflict: "conflict", review_scope_changed: "conflict", review_closed: "conflict",
      invitation_conflict: "conflict", invitation_ledger_disabled: "forbidden",
      promotion_conflict: "conflict", promotion_approvals_disabled: "forbidden", promotion_not_executable: "forbidden",
      broadcast_conflict: "conflict", broadcast_approvals_disabled: "forbidden",
    };
    if (Object.hasOwn(refusals, code)) return workflowFailure(refusals[code]);
    if (["admin_request_broadcast_approval","admin_broadcast_approval_command","admin_stop_approved_broadcast"].includes(fn)) {
      const messages:Record<string,string>={
        broadcast_expired:"The approval or publication deadline has passed. Cancel and create a fresh request.",
        broadcast_session_unavailable:"Your live MFA session is unavailable or expired. Sign in and complete MFA again.",
        broadcast_authority_changed:"An operator's authority changed. Cancel this request and obtain a fresh independent approval.",
        invalid_broadcast_payload:"Use plain text without markup or control characters, a title up to 120 characters, a body up to 1,000, and an expiry within the next seven days.",
        broadcast_approval_required:"Publication requires the exact independently approved message. No broadcast was published by this attempt.",
      };
      if(Object.hasOwn(messages,code))return {status:"error",message:messages[code]};
    }
    if (fn === "admin_request_staff_promotion" || fn === "admin_staff_promotion_command") {
      const messages:Record<string,string>={
        promotion_expired:"This approval has expired. Create a new request for an independent review.",
        promotion_session_unavailable:"Your live MFA session is unavailable or expired. Sign in and complete MFA again before continuing.",
        promotion_authority_changed:"A participating operator's authority changed. Cancel this request and obtain fresh authorization.",
        promotion_target_changed:"The target's authority changed after this request. Cancel it and request a new review.",
        promotion_target_ineligible:"Choose an active existing staff member who is not already a super admin.",
        promotion_target_not_ready:"The target must have a confirmed mailbox, completed invitation setup and a verified MFA factor. No promotion was performed.",
      };
      if(Object.hasOwn(messages,code))return {status:"error",message:messages[code]};
    }
    if (fn === "admin_recover_staff_invitation" || fn === "admin_repair_staff_invitation_setup") {
      const messages: Record<string, string> = {
        invitation_grant_closed: "This pending grant was cancelled or its deadline passed. No invitation-based access can be granted. Existing account access requires the separate staff controls.",
        invitation_access_exists: "The account already has access, changed standing, or this assignment was recorded. Inspect current staff access; recovery will not overwrite it.",
        invitation_evidence_missing: "A matching invitation account is not confirmed. No account was created, no email sent and no role granted. Investigate the original attempt.",
        invitation_binding_mismatch: "The account does not match this invitation's evidence. No recovery change was committed.",
        invitation_setup_not_ready: "The server-owned setup marker is missing. No role was granted. Auth setup needs a separately verified repair; do not resend or alter an established account automatically.",
        invitation_setup_repair_disabled: "Setup repair is disabled by the database rollout control. No change was made.",
        invitation_session_unavailable: "Your live MFA session is unavailable or expired. Sign in and complete MFA again.",
        invitation_setup_ineligible: "Repair is limited to unused, active non-staff invitations with a missing setup marker. A sign-in, password, setup marker or changed account standing prevents repair. No setup was reopened.",
      };
      if (Object.hasOwn(messages, code)) return {status:"error",message:messages[code]};
    }
    const reviewMessages: Record<string,string> = {
      review_period_exists: "A campaign already exists for that month. Open the existing review instead of creating a duplicate.",
      review_incomplete: "This campaign still has pending, expired, changed or unverified access. Review every item before closing.",
      revocation_not_verified: "The account still has a staff role. Remove staff access through the separate staff controls before confirming revocation.",
      review_scope_exceeds_limit: "This campaign exceeds the 500-staff snapshot limit. No partial campaign was created; batched enrollment is required.",
      invalid_attestation: "Retention requires an active staff account and an expiry within 90 days.",
      invalid_reviewer: "Choose a currently active super admin other than the subject.",
    };
    if(fn.startsWith("admin_create_access_review")||fn==="admin_access_review_command") {
      if(Object.hasOwn(reviewMessages,code))return {status:"error",message:reviewMessages[code]};
    }
    if (!started) return { status: "error", message: "Preflight checks could not be completed. No operation was submitted. Your inputs are retained." };
    return workflowFailure("failed");
  }
}
