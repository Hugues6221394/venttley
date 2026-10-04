"use server";

import { governanceAction, governanceInteger, governanceUtcTime } from "./governance-action";
import { enumOf, InvalidInput, reqStr, uuid } from "./validate";
import type { WorkflowResult } from "./workflow-model";

const unavailable=():WorkflowResult=>({status:"error",message:"Access-review controls are disabled. No change was submitted."});
export async function createAccessReview(fd: FormData) {
  if(process.env.ADMIN_ACCESS_REVIEWS_UI!=="true")return unavailable();
  return governanceAction(["super_admin"],"admin_create_access_review",()=>{
    const period=reqStr(fd,"period",7);
    if(!/^\d{4}-(0[1-9]|1[0-2])$/.test(period))throw new InvalidInput("period","use a review month");
    return {p_operation:uuid(fd,"operation_id"),p_period:`${period}-01`,p_due_at:governanceUtcTime(fd,"due_at")};
  },"Review campaign created with a frozen staff scope. This does not approve or change anyone's access.");
}
export async function commandAccessReview(fd: FormData) {
  if(process.env.ADMIN_ACCESS_REVIEWS_UI!=="true")return unavailable();
  return governanceAction(["super_admin"],"admin_access_review_command",()=>{
    const command=enumOf(fd,"command",["retain","require_revocation","confirm_revoked","refresh","reassign","close"] as const);
    return {
      p_operation:uuid(fd,"operation_id"),p_campaign:uuid(fd,"campaign_id"),
      p_subject:command==="close"?null:uuid(fd,"subject_id"),p_version:governanceInteger(fd,"version",1,999999),p_command:command,
      p_reason:command==="retain"?"business_need":command==="confirm_revoked"?"revocation_verified":command==="refresh"?"scope_changed":command==="require_revocation"?enumOf(fd,"reason_code",["no_business_need","inactive_access","role_mismatch"] as const):null,
      p_valid_until:command==="retain"?governanceUtcTime(fd,"valid_until"):null,
      p_reviewer:command==="reassign"?uuid(fd,"reviewer_id"):null,
    };
  },"Review record saved. A revocation requirement does not remove access; use the separate staff controls, then confirm the resulting state.");
}
