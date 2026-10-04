'use client';
import {useId,useRef,useState,useTransition} from 'react';
import {useRouter} from 'next/navigation';
import {findIncidentStaff,mutateIncident} from '@/lib/incident-actions';
import {incidentRunbooks,incidentServices,incidentSeverities,incidentSignals,incidentTransitions,type Incident,type IncidentStaff} from '@/lib/incident-model';
import {WorkflowForm} from '@/components/workflows/workflow-form';
import {OperatorDrawer} from '@/components/ui/operator-controls';

export function RefreshIncidents(){const router=useRouter(),[pending,start]=useTransition();return <button className="btn-secondary" disabled={pending} onClick={()=>start(()=>router.refresh())}>{pending?'Refreshing…':'Refresh incidents'}</button>;}
function StaffPicker({name,label,initial=[],multiple=false}:{name:string;label:string;initial?:IncidentStaff[];multiple?:boolean}){
 const [selected,setSelected]=useState(initial),[items,setItems]=useState<IncidentStaff[]>([]),[query,setQuery]=useState(''),[status,setStatus]=useState(''),[pending,setPending]=useState(false),serial=useRef(0),id=useId();
 async function search(){const request=++serial.current;setPending(true);setStatus('Searching…');try{const r=await findIncidentStaff(query);if(request!==serial.current)return;setItems(r.items);setStatus(r.error?'Staff search unavailable. Retry.':r.items.length?'Choose an eligible staff member.':'No matching eligible staff.');}catch{setStatus('Staff search unavailable. Retry.');}finally{if(request===serial.current)setPending(false);}}
 return <fieldset className="incident-staff"><legend>{label}</legend><div className="operator-actions"><input id={id} aria-label={`Search ${label.toLowerCase()}`} className="input" value={query} maxLength={50} onChange={e=>setQuery(e.target.value)}/><button type="button" className="btn-secondary" disabled={pending} onClick={search}>Find staff</button></div><p role="status">{status}</p>
  {selected.map(s=><div key={s.staff_id} className="incident-person"><input type="hidden" name={name} value={s.staff_id}/><span>{s.display_name}</span><button type="button" className="btn-ghost" onClick={()=>setSelected(v=>v.filter(x=>x.staff_id!==s.staff_id))} aria-label={`Remove ${s.display_name}`}>Remove</button></div>)}
  <ul>{items.filter(i=>!selected.some(s=>s.staff_id===i.staff_id)).map(i=><li key={i.staff_id}><button type="button" className="btn-ghost" disabled={multiple&&selected.length>=20} onClick={()=>{setSelected(v=>multiple?[...v,i]:[i]);setItems([]);}}>{i.display_name}</button></li>)}</ul>
  <small>Active admins and super admins only. {multiple?'Maximum 20 responders.':'Choose one person.'}</small></fieldset>;
}
const deadlineDefault=(value?:string)=>value?new Date(value).toISOString().slice(0,16):'';
// UTC is explicit; workstation/server zones must not silently move deadlines.
async function saveIncident(form:FormData){const value=form.get('deadline');if(typeof value==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value))form.set('deadline',`${value}:00Z`);return mutateIncident(form);}
export function IncidentForm({incident,command,actionId}:{incident?:Incident;command:string;actionId?:string}){
 const [operation]=useState(()=>crypto.randomUUID());
 const label=({declare:'Declare incident',coordinate:'Save coordination',transition:'Change phase',note:'Add update',action_add:'Add follow-up',action_complete:'Complete follow-up'} as Record<string,string>)[command];
 const team=command==='declare'||command==='coordinate';
 return <WorkflowForm key={`${incident?.version??'new'}-${command}-${actionId??''}`} action={saveIncident} label={label} confirmation="Save this internal coordination record? This does not execute containment, change permissions, publish a status page or page an external responder.">
  <input type="hidden" name="operation_id" value={operation}/><input type="hidden" name="command" value={command}/>{incident&&<><input type="hidden" name="incident_id" value={incident.incident_id}/><input type="hidden" name="version" value={incident.version}/></>}
  <div className={team?'incident-form-grid':''}><div>
   {command==='declare'&&<label>Incident title<input className="input" name="title" required maxLength={120}/></label>}
   {team&&<><label>Severity<select className="select" name="severity" defaultValue={incident?.severity??'sev2'}>{incidentSeverities.map(s=><option key={s}>{s}</option>)}</select></label>
    <fieldset><legend>Affected services (choose at least one)</legend><div className="incident-checks">{incidentServices.map(s=><label key={s}><input type="checkbox" name="services" value={s} defaultChecked={incident?.services.includes(s)}/>{s}</label>)}</div></fieldset>
    <StaffPicker name="commander" label="Commander" initial={incident?[{staff_id:incident.commander,display_name:incident.commander_name??'Current commander'}]:[]}/>
    <StaffPicker name="responders" label="Responders" multiple initial={incident?.responder_names??incident?.responders.map((id,index)=>({staff_id:id,display_name:`Current responder ${index+1}`}))}/>
    <label>Response deadline (UTC)<input className="input" type="datetime-local" name="deadline" required defaultValue={deadlineDefault(incident?.response_due_at)}/></label>
    <label>Internal runbook<select className="select" name="runbook" defaultValue={incident?.runbook??'system'}>{Object.keys(incidentRunbooks).map(k=><option key={k}>{k}</option>)}</select></label></>}
   {command==='transition'&&<label>Next phase<select className="select" name="status" required>{incident&&incidentTransitions[incident.status].map(s=><option key={s}>{s}</option>)}</select></label>}
   {command==='note'&&<label>Update type<select className="select" name="kind">{['update','decision','communication','postmortem'].map(k=><option key={k}>{k}</option>)}</select></label>}
   {command==='action_add'&&<><label>Follow-up title<input className="input" name="title" required maxLength={160}/></label><StaffPicker name="owner" label="Follow-up owner"/><label>Follow-up deadline (UTC)<input type="datetime-local" className="input" name="deadline" required/></label></>}
   {command==='action_complete'&&<input type="hidden" name="action" value={actionId}/>}</div><div>
   {team&&<label>Linked signal (optional)<select className="select" name="signal" defaultValue={incident?.signal??''}><option value="">No linked signal</option>{incidentSignals.map(s=><option key={s}>{s}</option>)}</select></label>}
   <label>Internal coordination note<textarea className="input" name="note" rows={6} maxLength={2000} required={command==='transition'||command==='note'}/></label>
   <p className="operator-note">Do not paste private messages, confession text, evidence, credentials or personal contact details. Use the separately authorized source workflow.</p>
  </div></div>
 </WorkflowForm>;
}
export function IncidentActions({incident}:{incident:Incident}){return incident.status==='reviewed'?<p className="operator-note">Reviewed record · read only</p>:<div className="operator-actions">{[['coordinate','Coordinate'],['transition','Change phase'],['note','Add update'],['action_add','Add follow-up']].map(([command,label])=><OperatorDrawer key={`${incident.version}-${command}`} title={label} trigger={label}><IncidentForm incident={incident} command={command}/></OperatorDrawer>)}</div>;}
