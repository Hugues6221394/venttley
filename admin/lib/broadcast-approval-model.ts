import { isUuid } from "./inbox-model";
import { invitationCursor, type InvitationCursor } from "./staff-invitation-model";
export type BroadcastApprovalCursor = InvitationCursor & {source:string|null};
export function broadcastApprovalCursor(params:Record<string,string|string[]|undefined>):BroadcastApprovalCursor|null {
  const cursor=invitationCursor(params);
  if(!cursor||params.source!==undefined&&(!isUuid(params.source)||cursor.beforeAt!==null))return null;
  return {...cursor,source:typeof params.source==="string"?params.source.toLowerCase():null};
}

export type BroadcastApproval = {
  approval_id: string; title: string; body: string; urgency: "info" | "warning" | "critical" | "crisis";
  state: "pending" | "approved" | "rejected" | "cancelled" | "published";
  version: number; created_at: string; expires_at: string; publication_expires_at: string;
  approved_at: string | null; published_at: string | null; broadcast_id: string | null;
  publication_active: boolean | null; requester_name: string; approver_name: string | null;
  expired: boolean; requested_by_me: boolean;
};
export type BroadcastApprovalRegister = {enabled:false} | {enabled:true;measured_at:string;items:BroadcastApproval[]};
const date = (v:unknown):v is string => typeof v==="string" && v.length<=40 && Number.isFinite(Date.parse(v));
export function parseBroadcastApprovalRegister(value:unknown):BroadcastApprovalRegister|null {
  if(!value||typeof value!=="object")return null;
  const r=value as Record<string,unknown>;
  if(r.enabled===false)return {enabled:false};
  if(r.enabled!==true||!date(r.measured_at)||!Array.isArray(r.items)||r.items.length>26)return null;
  for(const i of r.items) {
    if(!i||typeof i!=="object"||!isUuid(i.approval_id)||!Number.isSafeInteger(i.version)||i.version<1
      ||typeof i.title!=="string"||i.title.length===0||i.title.length>240
      ||typeof i.body!=="string"||i.body.length===0||i.body.length>2000
      ||!["info","warning","critical","crisis"].includes(i.urgency)
      ||!["pending","approved","rejected","cancelled","published"].includes(i.state)
      ||![i.created_at,i.expires_at,i.publication_expires_at].every(date)
      ||!(i.approved_at===null||date(i.approved_at))||!(i.published_at===null||date(i.published_at))
      ||!(i.broadcast_id===null||isUuid(i.broadcast_id))||!(i.publication_active===null||typeof i.publication_active==="boolean")
      ||typeof i.requester_name!=="string"||!(i.approver_name===null||typeof i.approver_name==="string")
      ||typeof i.expired!=="boolean"||typeof i.requested_by_me!=="boolean")return null;
  }
  return value as BroadcastApprovalRegister;
}
export function broadcastApprovalHref(item:BroadcastApproval) {
  return `/broadcasts?${new URLSearchParams({beforeAt:item.created_at,beforeId:item.approval_id})}`;
}
