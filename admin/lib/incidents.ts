import 'server-only';
import {createSsrClient,getRenderStaff} from './supabase/server';
import {hasModernShell} from './shell-rollout';
import type {IncidentQueue,IncidentDetail} from './incident-model';
export async function incidentUIEnabled(){const staff=await getRenderStaff();return !!staff&&['super_admin','admin'].includes(staff.role)&&process.env.ADMIN_INCIDENTS_UI==='true'&&hasModernShell(staff.role,process.env.ADMIN_SHELL_V2,process.env.ADMIN_SHELL_V2_ROLES);}
export async function incidentQueue(filters:{filter:string;severity:string;at:string|null;id:string|null}):Promise<IncidentQueue|null>{
 try{const db=await createSsrClient();const r=await db.rpc('admin_incident_queue',{p_filter:filters.filter,p_severity:filters.severity,p_before_at:filters.at,p_before_id:filters.id,p_limit:31}).abortSignal(AbortSignal.timeout(8000));return r.error?null:r.data as IncidentQueue;}catch{return null;}
}
export async function incidentDetail(id:string,before?:number):Promise<IncidentDetail|null>{
 try{const db=await createSsrClient();const r=await db.rpc('admin_incident_detail',{p_incident:id,p_before_version:before??null}).abortSignal(AbortSignal.timeout(8000));return r.error?null:r.data as IncidentDetail;}catch{return null;}
}
