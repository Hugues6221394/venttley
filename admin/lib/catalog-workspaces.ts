import "server-only";
import { notFound } from "next/navigation";
import { getOperationalRole } from "./governance";
import { createAdminClient } from "./supabase/server";
import { CATALOG_PAGE_SIZE, literalPrefix, type CatalogFilters, type TribeSummary, type MediaSummary, type MusicSummary } from "./catalog-workspace-model";

async function catalogClient() {
  const role=await getOperationalRole();
  if(!role||!["super_admin","admin","moderator"].includes(role))notFound();
  return createAdminClient();
}
export async function readTribeWorkspace(filters:CatalogFilters):Promise<TribeSummary[]|null> {
  const db=await catalogClient();
  try {
    let query=db.from("tribes").select("tribe_id,name,slug,category,is_private,is_active,is_featured,member_count,created_at")
      .order("tribe_id").limit(CATALOG_PAGE_SIZE+1);
    if(filters.after)query=query.gt("tribe_id",filters.after);
    if(filters.q)query=query.ilike("name",literalPrefix(filters.q));
    if(filters.state==="featured")query=query.eq("is_featured",true);
    if(filters.state==="active"||filters.state==="inactive")query=query.eq("is_active",filters.state==="active");
    const result=await query.abortSignal(AbortSignal.timeout(6000));
    return result.error?null:result.data as TribeSummary[];
  }catch{return null;}
}
export async function readMediaWorkspace(filters:CatalogFilters):Promise<MediaSummary[]|null> {
  const db=await catalogClient();
  try {
    const post=filters.kind==="post",id=post?"post_id":"whisper_id";
    // No authored text, storage URL, classifier free text or automatic preview.
    let query=db.from(post?"posts":"whispers").select(`${id},media_status,created_at,deleted_at`)
      .eq("media_status",filters.state).not(post?"image_url":"background_image_url","is",null)
      .order(id).limit(CATALOG_PAGE_SIZE+1);
    if(filters.after)query=query.gt(id,filters.after);
    const result=await query.abortSignal(AbortSignal.timeout(6000));
    if(result.error)return null;
    return (result.data as unknown as Record<string,unknown>[]).map(row=>({id:row[id] as string,status:row.media_status as string,created_at:row.created_at as string,deleted_at:row.deleted_at as string|null}));
  }catch{return null;}
}

export async function readMusicWorkspace(filters:CatalogFilters):Promise<MusicSummary[]|null> {
  const db=await catalogClient();
  try {
    let query=db.from("music_tracks").select("track_id,title,artist,provider,is_active,rights_holder,license_code,rights_expires_at,cache_allowed,allowed_regions")
      .order("track_id").limit(CATALOG_PAGE_SIZE+1);
    if(filters.after)query=query.gt("track_id",filters.after);
    if(filters.q)query=query.ilike("title",literalPrefix(filters.q));
    if(filters.provider)query=query.eq("provider",filters.provider);
    if(filters.state==="active"||filters.state==="inactive")query=query.eq("is_active",filters.state==="active");
    const now=new Date();
    if(filters.state==="expired")query=query.lt("rights_expires_at",now.toISOString());
    if(filters.state==="expiring")query=query.eq("is_active",true).gte("rights_expires_at",now.toISOString()).lte("rights_expires_at",new Date(now.getTime()+30*86400000).toISOString());
    const result=await query.abortSignal(AbortSignal.timeout(6000));
    return result.error?null:result.data as MusicSummary[];
  }catch{return null;}
}
