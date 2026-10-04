import "server-only";
import { createSsrClient } from "./supabase/server";
import { activeStaffRole } from "./staff";
import { parsePromotionCandidates, parsePromotionRegister, type PromotionCandidate, type promotionFilters } from "./promotion-model";

export async function readPromotions(filters:NonNullable<ReturnType<typeof promotionFilters>>) {
  if(process.env.ADMIN_PROMOTION_APPROVALS_UI!=="true")return null;
  try {
    const db=await createSsrClient();const {data:{user}}=await db.auth.getUser();
    if(!user||!await activeStaffRole(db,user.id,["super_admin"]))return null;
    const page=await db.rpc("admin_staff_promotion_register",{p_before_at:filters.beforeAt,p_before_id:filters.beforeId,...(filters.source?{p_source:filters.source}:{})}).abortSignal(AbortSignal.timeout(6000));
    if(page.error||!page.data)return null;
    const register=parsePromotionRegister(page.data);
    if(!register)return null;
    if(register.enabled===false)return {register,candidates:[] as PromotionCandidate[],candidatesUnavailable:false};
    if(filters.source) {
      if(register.items.length>1||register.items.some(i=>i.approval_id!==filters.source))return null;
      return {register,candidates:[] as PromotionCandidate[],candidatesUnavailable:false};
    }
    if(register.enabled!==true||!Array.isArray(register.items)||register.items.length>26)return null;
    const candidates=await db.rpc("admin_staff_promotion_candidates",{p_query:filters.query}).abortSignal(AbortSignal.timeout(6000));
    const parsed=candidates.error?null:parsePromotionCandidates(candidates.data);
    return {register,candidates:parsed??[],candidatesUnavailable:parsed===null};
  }catch{return null;}
}
