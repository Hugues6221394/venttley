import { isUuid } from "./inbox-model";
export type CatalogKind = "tribes" | "media" | "music";
export type CatalogFilters = { after:string|null; q:string; state:string; kind:"post"|"whisper";provider:string };
export const CATALOG_PAGE_SIZE=25;
export function catalogFilters(kind:CatalogKind,params:Record<string,string|string[]|undefined>):CatalogFilters|null {
  for(const key of ["after","q","state","kind","provider"])if(params[key]!==undefined&&typeof params[key]!=="string")return null;
  const after=typeof params.after==="string"?params.after:null;
  const q=typeof params.q==="string"?params.q.trim():"";
  const state=typeof params.state==="string"?params.state:kind==="media"?"pending":"all";
  const source=params.kind??"post";
  const provider=typeof params.provider==="string"?params.provider.trim():"";
  if(after!==null&&!isUuid(after)||q.length>80||/[\u0000-\u001f\u007f]/.test(q)
    ||provider.length>60||/[\u0000-\u001f\u007f]/.test(provider)
    ||!(kind==="media"?["pending","sensitive","blocked"]:kind==="music"?["all","active","inactive","expired","expiring"]:["all","active","inactive","featured"]).includes(state)
    ||!['post','whisper'].includes(source as string))return null;
  return {after,q,state,kind:source as 'post'|'whisper',provider};
}
export function catalogHref(kind:CatalogKind,filters:CatalogFilters,after?:string) {
  const params=new URLSearchParams({state:filters.state});
  if(kind!=="media"&&filters.q)params.set("q",filters.q);
  if(kind==="music"&&filters.provider)params.set("provider",filters.provider);
  if(kind==="media")params.set("kind",filters.kind);
  if(after)params.set("after",after);
  return `/${kind}?${params}`;
}
export function literalPrefix(value:string) {return value.replace(/[\\%_*]/g,c=>`\\${c}`)+"%";}
export type TribeSummary={tribe_id:string;name:string;slug:string;category:string;is_private:boolean;is_active:boolean;is_featured:boolean;member_count:number;created_at:string};
export type MediaSummary={id:string;status:string;created_at:string;deleted_at:string|null};
export type MusicSummary={track_id:string;title:string;artist:string;provider:string;is_active:boolean;rights_holder:string;license_code:string;rights_expires_at:string|null;cache_allowed:boolean;allowed_regions:string[]|null};
