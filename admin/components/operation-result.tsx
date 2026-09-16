import { CapabilityNotice, DataWarning } from "@/components/ui/operations";

const success: Record<string, string> = {
  case_created: "Support case created.", case_updated: "Support case updated.",
  request_registered: "Legal request registered.", decision_recorded: "Independent decision recorded.",
  fulfilment_recorded: "Disclosure completion receipt recorded.", draft_created: "Playbook draft created.",
  playbook_published: "Playbook published.", playbook_acknowledged: "Exact playbook version acknowledged.",
  drill_scheduled: "Recovery drill scheduled.", results_recorded: "Recovery drill results recorded.",
  drill_verified: "Recovery drill independently verified.",
};

const failure: Record<string, string> = {
  mfa_required: "Complete MFA step-up at /mfa, then submit again.",
  independent_operator_required: "A different super admin must perform this approval or verification.",
  forbidden: "Your active staff role cannot perform this operation.",
  retry_mismatch: "That operation ID was already used with different inputs. Reload before retrying.",
  rate_limited: "The server-side operation limit was reached. Wait before trying again; repeated retries will not bypass it.",
  not_found: "The selected record no longer exists or is not in an actionable state.",
  invalid_input: "The request was rejected by server-side validation. Review every field and try again.",
  failed: "The operation failed without changing the workflow. Check the audit and database logs before retrying.",
};

export function OperationResult({ code }: { code?: string }) {
  if (!code) return null;
  if (success[code]) return <CapabilityNotice title="Operation completed">{success[code]}</CapabilityNotice>;
  return <DataWarning title="Operation not completed">{failure[code] ?? "Unknown operation result."}</DataWarning>;
}
