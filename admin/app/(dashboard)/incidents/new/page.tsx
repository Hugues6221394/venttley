import {notFound} from 'next/navigation';
import Link from 'next/link';
import {incidentUIEnabled,incidentQueue} from '@/lib/incidents';
import {OperatorPage,OperatorPanel} from '@/components/ui/operator-workspace';
import {IncidentForm} from '@/components/incidents/incident-controls';
export const dynamic='force-dynamic';
export default async function Page(){
 if(!await incidentUIEnabled())notFound();
 const state=await incidentQueue({filter:'active',severity:'all',at:null,id:null});
 return <OperatorPage title="Declare incident" subtitle="Create an internal record to coordinate response and follow-ups." actions={<Link href="/incidents">Back to Incident Command</Link>}><OperatorPanel title="Incident details">{state?.enabled?<IncidentForm command="declare"/>:<p role="status">Incident coordination is disabled or unavailable. No declaration can be made.</p>}</OperatorPanel></OperatorPage>;
}
