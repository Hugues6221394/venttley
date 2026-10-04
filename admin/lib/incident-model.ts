import { isUuid } from './inbox-model';
export const incidentServices=['auth','feed','chat','moderation','media','push','email','database'] as const;
export const incidentSeverities=['sev1','sev2','sev3','sev4'] as const;
export const incidentStates=['declared','investigating','mitigating','monitoring','resolved','reviewed'] as const;
export type IncidentState=typeof incidentStates[number];
export const incidentTransitions:Record<IncidentState,IncidentState[]>={declared:['investigating'],investigating:['mitigating'],mitigating:['monitoring','investigating'],monitoring:['resolved','investigating'],resolved:['reviewed','investigating'],reviewed:[]};
export const incidentRunbooks={system:'/system',delivery:'/jobs',media:'/media',recovery:'/recovery-readiness',moderation:'/moderation'} as const;
export const incidentSignals=['crisis-posts','moderation-sla','push-dead','email-failed','media-stale'] as const;
export type Incident={incident_id:string;number:number;title:string;severity:string;status:IncidentState;services:string[];commander:string;commander_name:string|null;responders:string[];responder_names?:IncidentStaff[];response_due_at:string;runbook:keyof typeof incidentRunbooks;signal:string|null;version:number;created_at:string;updated_at:string};
export type IncidentEvent={event_id:string;version:number;kind:string;note:string;actor_name:string|null;created_at:string;detail:Record<string,unknown>};
export type IncidentAction={action_id:string;title:string;owner_id:string;owner_name:string|null;due_at:string;completed_at:string|null};
export type IncidentQueue={enabled:false}|{enabled:true;measured_at:string;rows:Incident[];active:number;overdue:number;review:number};
export type IncidentDetail={enabled:false}|{enabled:true;measured_at:string;incident:Incident;events:IncidentEvent[];actions:IncidentAction[]};
export type IncidentStaff={staff_id:string;display_name:string};
export const incidentTime=(value:string)=>new Date(value).toISOString().replace('T',' ').slice(0,16)+' UTC';
export function incidentFilters(params:URLSearchParams) {
 const filter=params.get('filter')??'active',severity=params.get('severity')??'all',at=params.get('beforeAt'),id=params.get('beforeId');
 if(!['active','mine','all','review'].includes(filter)||!['all',...incidentSeverities].includes(severity)||!!at!==!!id||(at&&(at.length>40||!Number.isFinite(Date.parse(at))||!isUuid(id))))return null;
 return {filter,severity,at,id};
}
export function incidentHref(filters:{filter:string;severity:string},next?:Incident) {
 const q=new URLSearchParams({filter:filters.filter,severity:filters.severity});if(next){q.set('beforeAt',next.created_at);q.set('beforeId',next.incident_id);}return `/incidents?${q}`;
}
