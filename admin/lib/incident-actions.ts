'use server';
import {createSsrClient,getRenderStaff} from './supabase/server';
import {requireOperationalActor,operationalResult} from './operational-actions';
import {incidentUIEnabled} from './incidents';
import {incidentRunbooks,incidentServices,incidentSeverities,incidentSignals,incidentStates,type IncidentStaff} from './incident-model';
import {isUuid} from './inbox-model';
import {workflowFailure,type WorkflowResult} from './workflow-model';
export async function findIncidentStaff(query:string):Promise<{items:IncidentStaff[];error:boolean}>{
 try{const staff=await getRenderStaff();if(!staff||!['super_admin','admin'].includes(staff.role)||!await incidentUIEnabled()||typeof query!=='string'||query.length>50)return {items:[],error:true};
 const db=await createSsrClient();const r=await db.rpc('admin_incident_staff',{p_query:query.trim()}).abortSignal(AbortSignal.timeout(8000));return {items:r.error?[]:r.data??[],error:!!r.error};}catch{return {items:[],error:true};}
}
export async function mutateIncident(form:FormData):Promise<WorkflowResult>{
 try{
  await requireOperationalActor(['super_admin','admin']);if(!await incidentUIEnabled())return workflowFailure('forbidden');
  const operation=form.get('operation_id'),id=form.get('incident_id'),command=form.get('command'),version=Number(form.get('version'));
  if(!isUuid(operation)||typeof command!=='string'||!['declare','coordinate','transition','note','action_add','action_complete'].includes(command))return workflowFailure('invalid_input');
  if(command!=='declare'&&(!isUuid(id)||!Number.isSafeInteger(version)||version<1))return workflowFailure('invalid_input');
  const text=(key:string,max:number,required=false)=>{const v=form.get(key);if(v!==null&&typeof v!=='string')throw Error('invalid_input');const s=String(v??'').trim();if(s.length>max||required&&!s)throw Error('invalid_input');return s;};
  const payload:Record<string,unknown>={note:text('note',2000)};
  if(command==='declare'||command==='coordinate'){
   const commander=text('commander',36,true),severity=text('severity',10,true),runbook=text('runbook',30,true),signal=text('signal',40),deadline=text('deadline',40,true);
   const services=form.getAll('services'),responders=form.getAll('responders');
   if(!isUuid(commander))return workflowFailure('invalid_input','commander');
   if(!/(Z|[+-]\d{2}:\d{2})$/.test(deadline)||!Number.isFinite(Date.parse(deadline)))return workflowFailure('invalid_input','deadline');
   if(!(incidentSeverities as readonly string[]).includes(severity)||!Object.hasOwn(incidentRunbooks,runbook)||signal&&!(incidentSignals as readonly string[]).includes(signal)||!services.length||services.length>8||services.some(v=>typeof v!=='string'||!(incidentServices as readonly string[]).includes(v))||responders.length>20||responders.some(v=>!isUuid(v)))return workflowFailure('invalid_input');
   Object.assign(payload,{commander,severity,runbook,signal,deadline:new Date(deadline).toISOString(),services,responders});if(command==='declare')payload.title=text('title',120,true);
  }else if(command==='transition'){payload.status=text('status',20,true);if(!(incidentStates as readonly unknown[]).includes(payload.status))return workflowFailure('invalid_input','status');}
  else if(command==='note'){payload.kind=text('kind',20,true);if(!['update','decision','communication','postmortem'].includes(String(payload.kind)))return workflowFailure('invalid_input','kind');}
  else if(command==='action_add'){payload.title=text('title',160,true);payload.owner=text('owner',36,true);const deadline=text('deadline',40,true);if(!isUuid(payload.owner)||!Number.isFinite(Date.parse(deadline)))return workflowFailure('invalid_input');payload.deadline=new Date(deadline).toISOString();}
  else{payload.action=text('action',36,true);if(!isUuid(payload.action))return workflowFailure('invalid_input');}
  const db=await createSsrClient();const {data,error}=await db.rpc('admin_incident_mutate',{p_operation:operation,p_incident:command==='declare'?null:id,p_version:command==='declare'?null:version,p_command:command,p_payload:payload}).abortSignal(AbortSignal.timeout(12000));
  if(error){if(error.code==='PT409')return {status:'error',message:'The incident changed, is reviewed, or still has open follow-ups. Refresh its current state before continuing.'};if(error.code==='55000')return {status:'error',message:'Incident coordination is disabled. Nothing was changed.'};if(['22023','22P02','23514','23502'].includes(error.code))return workflowFailure('invalid_input');return workflowFailure(operationalResult(new Error(error.message)));}
  return {status:'success',message:'Incident record saved. This does not page anyone externally or execute containment.',destination:isUuid(data)?`/incidents/records/${data}`:undefined};
 }catch(e){return workflowFailure(operationalResult(e));}
}
