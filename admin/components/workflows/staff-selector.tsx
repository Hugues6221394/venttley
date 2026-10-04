'use client';
import { useEffect,useId,useState } from 'react';
import { findSupportAssignees } from '@/lib/daily-workflow-actions';
import type { StaffOption } from '@/lib/workflows';

export function SupportStaffSelector({currentId,currentName}:{currentId:string|null;currentName:string|null}) {
  const id=useId(),[query,setQuery]=useState(''),[items,setItems]=useState<StaffOption[]>([]),[selected,setSelected]=useState(currentId??'');
  const [pending,setPending]=useState(false),[error,setError]=useState(false);
  const [chosen,setChosen]=useState<StaffOption|null>(null);
  useEffect(()=>{let active=true;setPending(true);findSupportAssignees('').then(r=>{if(active){setItems(r.items);setError(r.error);setPending(false);}}).catch(()=>{if(active){setError(true);setPending(false);}});return()=>{active=false;};},[]);
  const search=async()=>{setPending(true);setError(false);try{const r=await findSupportAssignees(query);setItems(r.items);setError(r.error);}catch{setError(true);}finally{setPending(false);}};
  return <div className="workflow-context"><label htmlFor={`${id}-query`}>Find eligible staff</label><div className="flex gap-2"><input id={`${id}-query`} className="input" value={query} maxLength={50} onChange={e=>setQuery(e.target.value)} placeholder="Name or username prefix"/><button type="button" className="btn-secondary" disabled={pending} onClick={search}>{pending?'Searching…':'Search staff'}</button></div>
    <label htmlFor={id}>Owner</label><select id={id} name="assignee_id" className="select" value={selected} onChange={e=>{setSelected(e.target.value);setChosen(items.find(i=>i.staff_id===e.target.value)??null);}}>
      <option value="">Unassigned</option>{currentId&&!items.some(i=>i.staff_id===currentId)&&<option value={currentId}>{currentName??'Current owner'} · eligibility rechecked on save</option>}
      {chosen&&chosen.staff_id!==currentId&&!items.some(i=>i.staff_id===chosen.staff_id)&&<option value={chosen.staff_id}>{chosen.display_name} · @{chosen.username}</option>}
      {items.map(i=><option value={i.staff_id} key={i.staff_id}>{i.display_name} · @{i.username}</option>)}
    </select>
    <p className="operator-note" role="status">{error?'Staff lookup unavailable. Retry; the selected owner has not been changed.':`Up to 25 eligible staff shown. ${items.length===25?'Refine the prefix to find more.':''}`}</p>
  </div>;
}
