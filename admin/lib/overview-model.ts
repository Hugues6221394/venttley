export const overviewPanels = ['activity', 'queues', 'reports', 'regions'] as const;
export type OverviewPanel = typeof overviewPanels[number];
export type Snapshot<T> = { state: 'ready' | 'stale' | 'unavailable'; measured_at: string | null; data: T | null };
export type Activity = { total_members: number; new_members: number; previous_members: number; unique_writers: number; vents: number; previous_vents: number; comments: number };
export type Queues = Partial<Record<'moderation' | 'appeals' | 'support', number>>;
export type ReportDay = { day: string; count: number };
export type Regions = { total_members: number; rows: { country: string; count: number }[] };
export type PanelData = { activity: Activity; queues: Queues; reports: ReportDay[]; regions: Regions };
const count = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
export function parseSnapshot<K extends OverviewPanel>(panel: K, value: unknown): Snapshot<PanelData[K]> | null {
  if (!object(value) || !['ready', 'stale', 'unavailable'].includes(String(value.state))) return null;
  if (value.state === 'unavailable') return { state: 'unavailable', measured_at: null, data: null };
  if (typeof value.measured_at !== 'string' || !Number.isFinite(Date.parse(value.measured_at))) return null;
  const d = value.data;
  const valid = panel === 'activity' ? object(d) && ['total_members','new_members','previous_members','unique_writers','vents','previous_vents','comments'].every(key=>count(d[key]))
    : panel === 'queues' ? object(d) && Object.entries(d).every(([key,v])=>['moderation','appeals','support'].includes(key) && count(v))
    : panel === 'reports' ? Array.isArray(d) && d.length <= 30 && d.every(row=>object(row) && typeof row.day==='string' && /^\d{4}-\d{2}-\d{2}$/.test(row.day) && Number.isFinite(Date.parse(row.day)) && count(row.count))
    : object(d) && count(d.total_members) && Array.isArray(d.rows) && d.rows.length <= 8 && d.rows.every(row=>object(row) && typeof row.country==='string' && /^[A-Z]{2}$/.test(row.country) && count(row.count) && row.count>=10 && row.count<=Number(d.total_members));
  return valid ? value as Snapshot<PanelData[K]> : null;
}
export function percentChange(current: number, previous: number): number | null {
  return previous === 0 ? null : Math.round((current - previous) / previous * 100);
}
export function regionPercent(count: number, total: number) { return total > 0 ? Math.round(count / total * 1000) / 10 : 0; }
export function snapshotStale(at: string | null, now = Date.now()) {
  const stamp = at ? Date.parse(at) : NaN;
  return !Number.isFinite(stamp) || now-stamp > 600_000 || stamp-now > 60_000;
}
export function dailyReports(rows: ReportDay[], measuredAt: string): ReportDay[] {
  const end = Date.parse(measuredAt.slice(0,10)+'T00:00:00Z');
  const values = new Map(rows.map(row=>[row.day,row.count]));
  return Array.from({length:30},(_,i)=>{ const day=new Date(end-(29-i)*86400_000).toISOString().slice(0,10); return {day,count:values.get(day)??0}; });
}
export const overviewDefinitions = [
  ['Registered members', 'Current rows in the member table, including staff and restricted accounts. Not verified humans or active users. Deleted accounts no longer present are excluded.'],
  ['Unique writers · 24h', 'Distinct non-null authors of a non-removed Vent or comment during the rolling 24 hours ending at the snapshot. Comments on removed Vents are excluded. An author appearing in both sets is counted once. This is not app-wide DAU.'],
  ['New members · 24h', 'Current member records created in the rolling 24-hour window. Compared with the immediately preceding 24 hours. No percentage is shown when the earlier count is zero.'],
  ['Vents created · 24h', 'Non-removed Vent records created in the rolling 24 hours. Includes limited-visibility or held content; it does not claim that every Vent was publicly published.'],
  ['Needs attention', 'Separate queue snapshots: unresolved moderation reports, open appeals, and non-resolved/non-closed support cases. The shared-attention pilot also includes legal requests awaiting approval for super admins. Only permitted queues appear. The same underlying issue can appear in multiple queues; these counts must not be added into unique incidents.'],
  ['Report volume', 'Reports submitted during the current UTC calendar day so far and the preceding 29 UTC days. Resolved reports remain in submission volume. Not a rolling 720-hour or open-workload measure.'],
  ['Member regions', 'Up to eight two-letter country groups with at least ten current accounts each. Percentages use all registered accounts as the denominator, not only the displayed regions. Unknown locations and smaller groups are withheld; percentages need not sum to 100%.'],
  ['Freshness', 'Activity and context are independently aggregated every five minutes once activated; snapshots older than ten minutes or with a failed refresh are stale. The shared-attention pilot checks every 30 seconds while visible, reconciles through the minute worker and marks changed or two-minute-old queue snapshots unknown. Refresh reads snapshots, never expensive aggregation.'],
] as const;
