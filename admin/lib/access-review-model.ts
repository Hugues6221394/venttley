import { isUuid } from "./inbox-model";

export type ReviewCampaign = { campaign_id: string; period: string; due_at: string; closed_at: string | null; version: number };
export type ReviewItem = {
  subject_id: string; subject_name: string; reviewer_id: string; reviewer_name: string; role_snapshot: string; status_snapshot: string;
  decision: "pending" | "retained" | "revoke_required" | "revoked"; reason_code: string | null; valid_until: string | null;
  version: number; assigned_to_me: boolean; scope_changed: boolean; is_self: boolean;
};
export type ReviewRegister = { enabled: false } | {
  enabled: true; measured_at: string; campaigns?: ReviewCampaign[]; campaign?: ReviewCampaign; items?: ReviewItem[];
  totals?: { total: number; pending: number; revocation_required: number; expired: number; changed: number };
  events?: { event_id: number; kind: string; reason_code: string | null; created_at: string; actor_name:string; subject_name:string }[];
};
export type ReviewFilters = {campaign: string | null; after: string | null; before: string | null};
export function reviewFilters(params: Record<string, string | string[] | undefined>): ReviewFilters | null {
  const {campaign, after, before}=params;
  if ([campaign,after,before].some(Array.isArray)) return null;
  if (campaign!==undefined&&!isUuid(campaign)||after!==undefined&&!isUuid(after)||after&&!campaign||before&&campaign) return null;
  if (before!==undefined&&(typeof before!=="string"||!/^\d{4}-(0[1-9]|1[0-2])-01$/.test(before))) return null;
  return {campaign:campaign as string??null,after:after as string??null,before:before as string??null};
}
export function reviewHref(params: Partial<ReviewFilters>={}) {
  const query=new URLSearchParams();
  for(const [key,value]of Object.entries(params))if(value)query.set(key,value);
  return `/staff/access-reviews${query.size?`?${query}`:""}`;
}
