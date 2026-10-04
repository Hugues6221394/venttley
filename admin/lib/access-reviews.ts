import "server-only";
import { createSsrClient } from "./supabase/server";
import { activeStaffRole } from "./staff";
import type { ReviewFilters, ReviewRegister } from "./access-review-model";

export async function readAccessReviews(filters: ReviewFilters): Promise<{register: ReviewRegister; reviewers: {staff_id:string;display_name:string;username:string}[]} | null> {
  if(process.env.ADMIN_ACCESS_REVIEWS_UI!=="true")return null;
  try {
    const db=await createSsrClient();
    const {data:{user}}=await db.auth.getUser();
    if(!user||!await activeStaffRole(db,user.id,["super_admin"]))return null;
    const response=await db.rpc("admin_access_review_register",{p_campaign:filters.campaign,p_after:filters.after,p_before:filters.before}).abortSignal(AbortSignal.timeout(6000));
    if(response.error||!response.data)return null;
    const register=response.data as ReviewRegister;
    if(!register.enabled)return {register,reviewers:[]};
    const staff=await db.rpc("admin_access_review_reviewers").abortSignal(AbortSignal.timeout(6000));
    // Reviewer selection failure must not imply an empty healthy staff directory.
    if(staff.error)return null;
    return {register,reviewers:staff.data??[]};
  }catch{return null;}
}
