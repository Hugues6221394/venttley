import "server-only";

import { createSsrClient } from "@/lib/supabase/server";
import { activeStaffRole } from "@/lib/staff";

type Result<T> = { data: T[]; error: string | null };

export type SupportCase = {
  support_case_id: string; source_kind: string; source_id: string | null; member_id: string | null;
  category: string; priority: string; status: string; assignee_id: string | null; assignee_name: string | null;
  sla_due_at: string; first_response_at: string | null; resolved_at: string | null; created_at: string; updated_at: string;
};

export type LegalRequest = {
  legal_request_id: string; request_type: string; jurisdiction: string; scope_code: string; status: string;
  requester_verified: boolean; due_at: string; created_by: string; approved_by: string | null; approved_at: string | null;
  approval_reason_code: string | null; manifest_recorded: boolean; fulfilled_at: string | null;
  completion_recorded: boolean; created_at: string; updated_at: string;
};

export type CrisisPlaybook = {
  playbook_id: string; region_code: string; version: number; title: string; body_markdown: string; body_hash: string;
  status: string; created_by: string; published_by: string | null; created_at: string; published_at: string | null;
  acknowledgement_count: number; acknowledged_by_me: boolean;
};

export type RecoveryDrill = {
  recovery_drill_id: string; environment: string; status: string; scheduled_at: string;
  expected_rpo_minutes: number; expected_rto_minutes: number; actual_rpo_minutes: number | null; actual_rto_minutes: number | null;
  checks_passed: number | null; checks_total: number | null; evidence_recorded: boolean; created_by: string;
  completed_by: string | null; verified_by: string | null; completed_at: string | null; verified_at: string | null; created_at: string;
};

async function rows<T>(fn: string, limit: number): Promise<Result<T>> {
  const supabase = await createSsrClient();
  const result = await supabase.rpc(fn, { p_limit: limit });
  return result.error
    ? { data: [], error: result.error.message }
    : { data: (result.data as T[] | null) ?? [], error: null };
}

export const getSupportCases = (limit = 100) => rows<SupportCase>("admin_support_case_queue", limit);
export const getLegalRequests = (limit = 100) => rows<LegalRequest>("admin_legal_request_queue", limit);
export const getCrisisPlaybooks = (limit = 50) => rows<CrisisPlaybook>("admin_crisis_playbooks", limit);
export const getRecoveryDrills = (limit = 50) => rows<RecoveryDrill>("admin_recovery_drills", limit);

export async function getOperationalRole() {
  const supabase = await createSsrClient();
  const { data: { user } } = await supabase.auth.getUser();
  return user ? activeStaffRole(supabase, user.id) : null;
}
