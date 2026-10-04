import 'server-only';
import { notFound } from 'next/navigation';
import { createAdminClient, createSsrClient, getRenderStaff } from './supabase/server';
import { canAccess } from './roles';
import { analyticsDays, analyticsRange, analyticsSampleLimit, parseEngagement, parseActiveDays, parseRetention, parseSample,
  type AnalyticsData, type AnalyticsPanel, type AnalyticsRange, type AnalyticsResult } from './analytics-model';

export async function requireAnalyticsAccess() {
  const staff=await getRenderStaff();
  if (!staff || !canAccess(staff.role,'/analytics')) notFound();
}
// Each independently streamed panel checks its own authorization. No cross-user
// data/permission caching, no service-role RPC calls, no mutation or new grants.
export async function readAnalyticsPanel<K extends AnalyticsPanel>(panel:K,range:AnalyticsRange):Promise<AnalyticsResult<AnalyticsData[K]>> {
  await requireAnalyticsAccess();
  const unavailable={data:null,receivedAt:null};
  const days=analyticsDays(analyticsRange(range));
  try {
    const signal=AbortSignal.timeout(8_000);
    const receivedAt=new Date().toISOString();
    let data:unknown;
    if(panel==='samples') {
      const db=await createAdminClient();
      const since=new Date(Date.parse(receivedAt.slice(0,10)+'T00:00:00Z')-(days-1)*86400_000).toISOString();
      const specs=[['posts','posts','created_at,category_name'],['comments','posts_comments','created_at'],['reactions','post_likes','created_at'],['reports','reports','created_at,resolved_at,is_resolved']] as const;
      const pairs=await Promise.all(specs.map(async([kind,table,fields])=>{
        try {
          let q=db.from(table).select(fields).gte('created_at',since).lte('created_at',receivedAt).order('created_at',{ascending:false}).limit(analyticsSampleLimit);
          if(kind==='posts')q=q.is('deleted_at',null);
          const result=await q.abortSignal(signal);
          return [kind,result.error?null:parseSample(result.data,kind,since,receivedAt)] as const;
        } catch {return [kind,null] as const;}
      }));
      data=Object.fromEntries(pairs) as AnalyticsData['samples'];
    } else {
      const db=await createSsrClient();
      const names={engagement:'admin_engagement_totals',daily:'admin_active_users_daily',retention:'admin_new_user_retention'};
      const args=panel==='daily'?{p_days:days}:panel==='retention'?{p_weeks:6}:{};
      const result=await db.rpc(names[panel as Exclude<AnalyticsPanel,'samples'>],args).abortSignal(signal);
      if(result.error)return unavailable;
      data=panel==='engagement'?parseEngagement(result.data):panel==='daily'?parseActiveDays(result.data,days):parseRetention(result.data);
    }
    return data ? {data:data as AnalyticsData[K],receivedAt} : unavailable;
  } catch { return unavailable; }
}
