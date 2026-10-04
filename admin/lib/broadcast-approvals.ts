import "server-only";
import { createSsrClient } from "./supabase/server";
import { activeStaffRole } from "./staff";
import { parseBroadcastApprovalRegister, type BroadcastApprovalCursor } from "./broadcast-approval-model";

export async function readBroadcastApprovals(cursor:BroadcastApprovalCursor) {
  if(process.env.ADMIN_BROADCAST_APPROVALS_UI!=="true")return null;
  try {
    const db=await createSsrClient();
    const {data:{user}}=await db.auth.getUser();
    if(!user||!await activeStaffRole(db,user.id,["super_admin","admin"]))return null;
    const result=await db.rpc("admin_broadcast_approval_register",{p_before_at:cursor.beforeAt,p_before_id:cursor.beforeId,...(cursor.source?{p_source:cursor.source}:{})})
      .abortSignal(AbortSignal.timeout(6000));
    const register=result.error?null:parseBroadcastApprovalRegister(result.data);
    if(cursor.source&&register?.enabled&&(register.items.length>1||register.items.some(i=>i.approval_id!==cursor.source)))return null;
    return register;
  }catch{return null;}
}
