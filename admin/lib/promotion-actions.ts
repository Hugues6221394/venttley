"use server";
import { governanceAction, governanceInteger } from "./governance-action";
import { enumOf, uuid } from "./validate";
import type { WorkflowResult } from "./workflow-model";
const disabled=():WorkflowResult=>({status:"error",message:"Promotion approvals are not enabled in this console. No command was submitted."});
export async function requestPromotion(fd:FormData) {
  if(process.env.ADMIN_PROMOTION_APPROVALS_UI!=="true")return disabled();
  return governanceAction(["super_admin"],"admin_request_staff_promotion",()=>({
    p_operation:uuid(fd,"operation_id"),p_target:uuid(fd,"target_id"),
    p_reason_code:enumOf(fd,"reason_code",["operational_coverage","succession","security_oversight"] as const),
  }),"Promotion requested for independent review. No role has changed.");
}
export async function commandPromotion(fd:FormData) {
  if(process.env.ADMIN_PROMOTION_APPROVALS_UI!=="true")return disabled();
  return governanceAction(["super_admin"],"admin_staff_promotion_command",()=>({
    p_operation:uuid(fd,"operation_id"),p_approval:uuid(fd,"approval_id"),
    p_version:governanceInteger(fd,"version",1,999999),p_command:enumOf(fd,"command",["approve","reject","cancel","execute"] as const),
  }),"Approval operation committed. Refresh to inspect its state; approval alone does not execute a promotion.");
}
