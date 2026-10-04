export type AnalyticsRange = '7d' | '30d' | '90d';
export const analyticsSampleLimit = 500;
export function analyticsRange(value: unknown): AnalyticsRange {
  return value === '7d' || value === '90d' ? value : '30d';
}
export const analyticsDays = (range: AnalyticsRange) => range === '7d' ? 7 : range === '90d' ? 90 : 30;
export type Engagement = { total_users:number; active_1d:number; active_7d:number; active_30d:number; new_7d:number; new_30d:number; stickiness:number };
export type ActiveDay = { day:string; active_users:number; new_users:number };
export type RetentionRow = { cohort_week:string; cohort_size:number; week_offset:number; retained:number };
export type SampleRow = { created_at:string; category_name?:string | null; resolved_at?:string | null; is_resolved?:boolean };
export type SampleKind = 'posts' | 'comments' | 'reactions' | 'reports';
export type AnalyticsData = { engagement:Engagement; daily:ActiveDay[]; retention:RetentionRow[]; samples:Record<SampleKind,SampleRow[] | null> };
export type AnalyticsPanel = keyof AnalyticsData;
export type AnalyticsResult<T> = { data:T | null; receivedAt:string | null };
const object = (v:unknown):v is Record<string,unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const count = (v:unknown):v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;
const date = (v:unknown):v is string => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) && Number.isFinite(Date.parse(v)) && new Date(v).toISOString().slice(0,10) === v;
const instant = (v:unknown):v is string => typeof v === 'string' && /^\d{4}-\d\d-\d\dT/.test(v) && Number.isFinite(Date.parse(v));
export function parseEngagement(value:unknown):Engagement | null {
  if (!Array.isArray(value) || value.length !== 1 || !object(value[0])) return null;
  const r=value[0];
  if (!['total_users','active_1d','active_7d','active_30d','new_7d','new_30d'].every(k=>count(r[k])) ||
      typeof r.stickiness !== 'number' || !Number.isFinite(r.stickiness) || r.stickiness<0 || r.stickiness>1 ||
      Number(r.active_1d)>Number(r.active_7d) || Number(r.active_7d)>Number(r.active_30d)) return null;
  // Project allowed fields; never pass unexpected payload fields to components.
  return {total_users:Number(r.total_users),active_1d:Number(r.active_1d),active_7d:Number(r.active_7d),active_30d:Number(r.active_30d),new_7d:Number(r.new_7d),new_30d:Number(r.new_30d),stickiness:r.stickiness};
}
export function parseActiveDays(value:unknown,days:number):ActiveDay[] | null {
  if (!Array.isArray(value) || value.length !== days) return null;
  const rows:ActiveDay[]=[];
  for (const r of value) {
    if (!object(r) || !date(r.day) || !count(r.active_users) || !count(r.new_users)) return null;
    if (rows.length && Date.parse(r.day)-Date.parse(rows.at(-1)!.day)!==86400_000) return null;
    rows.push({day:r.day,active_users:r.active_users,new_users:r.new_users});
  }
  return rows;
}
export function parseRetention(value:unknown):RetentionRow[] | null {
  if (!Array.isArray(value) || value.length>36) return null;
  const rows:RetentionRow[]=[], sizes=new Map<string,number>(), seen=new Set<string>();
  for (const r of value) {
    if (!object(r)||!date(r.cohort_week)||!count(r.cohort_size)||r.cohort_size===0||!count(r.week_offset)||r.week_offset>5||!count(r.retained)||r.retained>r.cohort_size) return null;
    const key=`${r.cohort_week}:${r.week_offset}`;
    if (seen.has(key) || (sizes.has(r.cohort_week) && sizes.get(r.cohort_week)!==r.cohort_size)) return null;
    seen.add(key);sizes.set(r.cohort_week,r.cohort_size);
    rows.push({cohort_week:r.cohort_week,cohort_size:r.cohort_size,week_offset:r.week_offset,retained:r.retained});
  }
  return sizes.size<=6 ? rows : null;
}
export function parseSample(value:unknown,kind:SampleKind,since:string,until:string):SampleRow[] | null {
  if (!Array.isArray(value) || value.length>analyticsSampleLimit) return null;
  const rows:SampleRow[]=[];
  for (const r of value) {
    if (!object(r)||!instant(r.created_at)||Date.parse(r.created_at)<Date.parse(since)||Date.parse(r.created_at)>Date.parse(until)) return null;
    if (rows.length && Date.parse(r.created_at)>Date.parse(rows.at(-1)!.created_at)) return null;
    const row:SampleRow={created_at:r.created_at};
    if(kind==='posts') {
      if(r.category_name!==null && (typeof r.category_name!=='string'||r.category_name.length>100)) return null;
      row.category_name=r.category_name;
    }
    if(kind==='reports') {
      if(typeof r.is_resolved!=='boolean'||(r.resolved_at!==null&&!instant(r.resolved_at))) return null;
      if(r.resolved_at!==null&&Date.parse(r.resolved_at as string)<Date.parse(r.created_at)) return null;
      row.is_resolved=r.is_resolved;row.resolved_at=r.resolved_at as string | null;
    }
    rows.push(row);
  }
  return rows;
}
export function sampleSeries(rows:SampleRow[],days:number,until:string) {
  const last=Date.parse(until.slice(0,10)+'T00:00:00Z');
  const counts=new Map<string,number>();
  rows.forEach(r=>{const key=new Date(r.created_at).toISOString().slice(0,10);counts.set(key,(counts.get(key)??0)+1);});
  return Array.from({length:days},(_,i)=>{const day=new Date(last-(days-1-i)*86400_000).toISOString().slice(0,10);return {day,count:counts.get(day)??0};});
}
export function retentionBand(retained:number,size:number):0|1|2|3|4 {
  const percent=size>0?Math.min(1,Math.max(0,retained/size)):0;
  return Math.min(4,Math.floor(percent*5)) as 0|1|2|3|4;
}
export function sampleResolution(rows:SampleRow[]) {
  const resolved=rows.filter(r=>r.is_resolved && r.resolved_at);
  return {observations:resolved.length,minutes:resolved.length?Math.round(resolved.reduce((sum,r)=>sum+Date.parse(r.resolved_at!)-Date.parse(r.created_at),0)/resolved.length/60_000):null};
}
