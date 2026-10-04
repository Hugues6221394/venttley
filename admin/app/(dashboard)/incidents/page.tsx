import {Suspense} from 'react';
import Link from 'next/link';
import LegacyIncidents from '@/components/legacy-incidents';
import {OperatorPage,PanelSkeleton} from '@/components/ui/operator-workspace';
import {incidentUIEnabled} from '@/lib/incidents';
import {IncidentQueuePanel} from '@/components/incidents/incident-queue';
import {RefreshIncidents} from '@/components/incidents/incident-controls';
export const dynamic='force-dynamic';
export default async function IncidentsPage({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}) {
 const params=await searchParams;
 if(!await incidentUIEnabled()||params.view==='signals')return <LegacyIncidents/>;
 return <OperatorPage title="Incident command" subtitle="Coordinate response, ownership and follow-through." actions={<><Link className="btn-primary" href="/incidents/new">Declare incident</Link><Link className="btn-secondary" href="/incidents?view=signals">Signal directory</Link><RefreshIncidents/></>}>
  <Suspense fallback={<PanelSkeleton label="incident response queue"/>}><IncidentQueuePanel params={params}/></Suspense>
  <p className="incident-advisory">Containment and evidence access stay separately authorized. Opening an incident does not execute a rollback, page anyone externally or publish a status update.</p>
 </OperatorPage>;
}
