import Link from 'next/link';
import { Suspense } from 'react';
import { requireAnalyticsAccess } from '@/lib/analytics';
import { analyticsRange } from '@/lib/analytics-model';
import { OperatorPage, PanelSkeleton } from '@/components/ui/operator-workspace';
import { AnalyticsEngagement, AnalyticsDaily, AnalyticsRetention, AnalyticsSamples } from '@/components/analytics-panels';
import { RegionsPanel } from '@/components/overview-panels';

export const dynamic='force-dynamic';
export default async function AnalyticsPage({searchParams}:{searchParams:Promise<{range?:string|string[]}>}) {
  await requireAnalyticsAccess();
  const range=analyticsRange((await searchParams).range);
  return <OperatorPage title="Analytics" subtitle="Understand activity without confusing snapshots, samples and live operational counts." actions={
    <nav aria-label="Analytics chart window" className="flex flex-wrap gap-2">{(['7d','30d','90d'] as const).map(value=><Link key={value} href={`/analytics?range=${value}`} prefetch={false} aria-current={range===value?'page':undefined} className={range===value?'btn-primary':'btn-secondary'}>{value}</Link>)}</nav>
  }>
    <Suspense fallback={<PanelSkeleton label="member engagement"/>}><AnalyticsEngagement range={range}/></Suspense>
    <Suspense fallback={<PanelSkeleton label="daily analytics"/>}><AnalyticsDaily range={range}/></Suspense>
    <Suspense fallback={<PanelSkeleton label="retention"/>}><AnalyticsRetention range={range}/></Suspense>
    <Suspense fallback={<PanelSkeleton label="member regions"/>}><RegionsPanel/></Suspense>
    <Suspense fallback={<PanelSkeleton label="recent record samples"/>}><AnalyticsSamples range={range}/></Suspense>
  </OperatorPage>;
}
