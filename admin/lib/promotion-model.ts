import { invitationCursor } from "./staff-invitation-model";
import { isUuid } from "./inbox-model";
export type PromotionItem = {
  approval_id: string; target_name: string; requester_name: string; approver_name: string | null;
  target_role: string; reason_code: string; state: "pending" | "approved" | "rejected" | "cancelled" | "executed";
  version: number; created_at: string; expires_at: string; approved_at: string | null; executed_at: string | null;
  expired: boolean; requested_by_me: boolean; targets_me: boolean;
};
export type PromotionRegister = {enabled:false}|{enabled:true;measured_at:string;items:PromotionItem[]};
export type PromotionCandidate = {user_id:string;display_name:string;username:string;role:string};
const dateValue=(v:unknown):v is string=>typeof v==="string"&&v.length<=40&&Number.isFinite(Date.parse(v));
export function parsePromotionRegister(value:unknown):PromotionRegister|null {
  if(!value||typeof value!=="object")return null;
  const r=value as Record<string,unknown>;
  if(r.enabled===false)return {enabled:false};
  if(r.enabled!==true||!dateValue(r.measured_at)||!Array.isArray(r.items)||r.items.length>26)return null;
  for(const i of r.items) {
    if(!i||typeof i!=="object"||!isUuid(i.approval_id)||!Number.isSafeInteger(i.version)||i.version<1
      ||!["pending","approved","rejected","cancelled","executed"].includes(i.state)
      ||![i.target_name,i.requester_name,i.target_role,i.reason_code].every(v=>typeof v==="string")
      ||!(i.approver_name===null||typeof i.approver_name==="string")
      ||!dateValue(i.created_at)||!dateValue(i.expires_at)
      ||!(i.approved_at===null||dateValue(i.approved_at))||!(i.executed_at===null||dateValue(i.executed_at))
      ||![i.expired,i.requested_by_me,i.targets_me].every(v=>typeof v==="boolean"))return null;
  }
  return value as PromotionRegister;
}
export function parsePromotionCandidates(value:unknown):PromotionCandidate[]|null {
  if(!Array.isArray(value)||value.length>26)return null;
  if(!value.every(c=>c&&typeof c==="object"&&isUuid(c.user_id)&&[c.display_name,c.username,c.role].every(v=>typeof v==="string")))return null;
  return value as PromotionCandidate[];
}
export function promotionFilters(params:Record<string,string|string[]|undefined>) {
  const cursor=invitationCursor(params);
  if(!cursor||typeof params.q!=="undefined"&&(typeof params.q!=="string"||!/^[a-zA-Z0-9_]{0,24}$/.test(params.q)))return null;
  if(params.source!==undefined&&(!isUuid(params.source)||cursor.beforeAt!==null||params.q!==undefined))return null;
  return {...cursor,source:typeof params.source==="string"?params.source.toLowerCase():null,query:typeof params.q==="string"?params.q:""};
}
export function promotionHref(item:PromotionItem) {
  return `/approvals?${new URLSearchParams({beforeAt:item.created_at,beforeId:item.approval_id})}`;
}
