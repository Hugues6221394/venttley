import "server-only";

import { createSsrClient } from "@/lib/supabase/server";
import { activeStaffRole } from "@/lib/staff";
import { limitAction } from "@/lib/guard";

export async function requireOperationalActor(roles: readonly string[]): Promise<void> {
  await limitAction("destructive");
  const supabase = await createSsrClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user || !(await activeStaffRole(supabase, user.id, roles))) {
    throw new Error("not_authorized");
  }
}

export function operationalResult(error: unknown): string {
  const message = error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase();
  if (message.includes("aal2") || message.includes("mfa")) return "mfa_required";
  if (message.includes("independent")) return "independent_operator_required";
  if (message.includes("not_authorized") || message.includes("forbidden")) return "forbidden";
  if (message.includes("idempotency_payload_mismatch")) return "retry_mismatch";
  if (message.includes("rate_limited")) return "rate_limited";
  if (message.includes("not_found")) return "not_found";
  if (message.includes("invalid") || message.includes("required") || message.includes("must be")) return "invalid_input";
  return "failed";
}
