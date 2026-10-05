import { Suspense } from 'react';
import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getRenderStaff } from '@/lib/supabase/server';
import { hasModernShell } from '@/lib/shell-rollout';
import { canAccess } from '@/lib/roles';
import LegacyOverview from '@/components/legacy-overview';
import { OperatorPage, OperatorPanel, PanelSkeleton } from '@/components/ui/operator-workspace';
import { OperatorDrawer, RefreshOverview } from '@/components/ui/operator-controls';
import { ActivityPanel, AttentionPanel, ReportsPanel, RegionsPanel } from '@/components/overview-panels';
import { overviewDefinitions } from '@/lib/overview-model';
import { Inbox, ScrollText, Siren, LifeBuoy, LineChart, ChevronRight } from 'lucide-react';

export const dynamic='force-dynamic';
export default async function OverviewPage() {
  const staff=await getRenderStaff();
  if(!staff)redirect('/login');
  if(process.env.ADMIN_OVERVIEW_V2!=='true'||!hasModernShell(staff.role,process.env.ADMIN_SHELL_V2,process.env.ADMIN_SHELL_V2_ROLES))return <LegacyOverview/>;
  return <OperatorPage title="A clear view of your community" subtitle="Activity, attention, and context. Each panel is independently verified."
    actions={<><RefreshOverview/><OperatorDrawer title="Metric definitions" trigger="Metric definitions"><dl className="operator-definitions">{overviewDefinitions.map(([name,definition])=><div key={name}><dt>{name}</dt><dd>{definition}</dd></div>)}</dl></OperatorDrawer></>}>
    <Suspense fallback={<PanelSkeleton label="community activity" className="operator-activity"/>}><ActivityPanel/></Suspense>
    <div className="operator-priority-grid">
      <Suspense fallback={<PanelSkeleton label="queue snapshots" className="operator-queue-panel"/>}><AttentionPanel/></Suspense>
      <OperatorPanel title="Your workspace" hint="Only destinations allowed by your role appear."><nav aria-label="Overview workspace" className="operator-shortcuts">
        {([['/inbox','Staff inbox',Inbox],['/audit','Audit log',ScrollText],['/incidents','Incident command',Siren],['/safety','Safety & crisis',LifeBuoy],['/analytics','Analytics',LineChart]] as const).filter(([href])=>canAccess(staff.role,href)).map(([href,label,Icon])=><Link key={href} href={href} prefetch={false}><span className="operator-shortcut-icon" aria-hidden="true"><Icon size={15}/></span><span>{label}</span><ChevronRight size={15} aria-hidden="true"/></Link>)}
      </nav><p className="operator-note">Overview contains aggregates only. Member content stays in its authorized workflow.</p></OperatorPanel>
    </div>
    <div className="operator-context-grid"><Suspense fallback={<PanelSkeleton label="report volume" className="operator-context-panel"/>}><ReportsPanel/></Suspense><Suspense fallback={<PanelSkeleton label="member regions" className="operator-context-panel"/>}><RegionsPanel/></Suspense></div>
    <p className="operator-note">Snapshots are not instant monitoring. Activity and context target a five-minute cadence once enabled; shared attention states its separate cadence. Missing or stale data is shown explicitly.</p>
  </OperatorPage>;
}
