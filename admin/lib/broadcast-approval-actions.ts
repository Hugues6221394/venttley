"use server";
import { governanceAction, governanceInteger, governanceUtcTime } from "./governance-action";
import { enumOf, reqStr, uuid } from "./validate";
import type { WorkflowResult } from "./workflow-model";
const disabled=():WorkflowResult=>({status:"error",message:"Broadcast approvals are not enabled in this console. No command was submitted."});
export async function requestBroadcastApproval(fd:FormData) {
  if(process.env.ADMIN_BROADCAST_APPROVALS_UI!=="true")return disabled();
  return governanceAction(["super_admin","admin"],"admin_request_broadcast_approval",()=>({
    p_operation:uuid(fd,"operation_id"),p_title:reqStr(fd,"title",120),p_body:reqStr(fd,"body",1000),
    p_urgency:enumOf(fd,"urgency",["info","warning","critical","crisis"] as const),p_expires_at:governanceUtcTime(fd,"expires_at"),
  }),"Broadcast submitted for independent review. Nothing has been published. Refresh to inspect the exact stored preview.");
}
export async function commandBroadcastApproval(fd:FormData) {
  if(process.env.ADMIN_BROADCAST_APPROVALS_UI!=="true")return disabled();
  return governanceAction(["super_admin","admin"],"admin_broadcast_approval_command",()=>({
    p_operation:uuid(fd,"operation_id"),p_approval:uuid(fd,"approval_id"),p_version:governanceInteger(fd,"version",1,999999),
    p_command:enumOf(fd,"command",["approve","reject","cancel","publish"] as const),
  }),"Broadcast operation committed. Refresh to inspect its state. Publication is not proof of delivery to devices.");
}
export async function stopApprovedBroadcast(fd:FormData) {
  if(process.env.ADMIN_BROADCAST_APPROVALS_UI!=="true")return disabled();
  return governanceAction(["super_admin","admin"],"admin_stop_approved_broadcast",()=>({
    p_operation:uuid(fd,"operation_id"),p_approval:uuid(fd,"approval_id"),
  }),"Broadcast deactivated. Already downloaded or delivered content cannot be recalled.");
}
