'use client';
import {useState,useRef} from 'react';
import {findSupportBindings} from '@/lib/daily-workflow-actions';
type Binding={id:string;member_id:string;label:string;context:string};
export function SupportBindings() {
 const [kind,setKind]=useState('other'),[query,setQuery]=useState(''),[items,setItems]=useState<Binding[]>([]),[chosen,setChosen]=useState<Binding|null>(null),[busy,setBusy]=useState(false),[error,setError]=useState(false),[searched,setSearched]=useState(false);
 const sequence=useRef(0);const source=['appeal','verification'].includes(kind);
 async function search(){const request=++sequence.current;setBusy(true);setError(false);const result=await findSupportBindings(source?kind:'member',query);if(request!==sequence.current)return;setBusy(false);setSearched(true);setError(result.error);if(!result.error)setItems(result.items);}
 return <>
   <label>Source type<select className="select" name="source_kind" value={kind} onChange={e=>{sequence.current++;setBusy(false);setKind(e.target.value);setChosen(null);setItems([]);setError(false);setSearched(false);}}>{['appeal','verification','privacy','account','recovery','safety','other'].map(s=><option key={s} value={s}>{s}</option>)}</select></label>
   <details className="workflow-technical"><summary>Link a member or source (optional)</summary><p>Search by username prefix (at least 4 characters) or exact record ID. Requires MFA; each lookup is audited.</p>
     <label>Find {source?kind:'member'}<input className="input" value={query} onChange={e=>setQuery(e.target.value)} maxLength={50}/></label>
     <button type="button" className="btn-secondary" disabled={busy||query.trim().length<4} onClick={search}>{busy?'Searching…':'Search records'}</button>
     {error&&<p role="alert">Lookup unavailable. Check MFA and staff access, then retry. Your selection is unchanged.</p>}
     <label>Linked record<select className="select" value={chosen?.id??''} onChange={e=>setChosen(items.find(i=>i.id===e.target.value)??(chosen?.id===e.target.value?chosen:null))}><option value="">No linked record</option>{chosen&&!items.some(i=>i.id===chosen.id)&&<option value={chosen.id}>{chosen.label} · {chosen.context}</option>}{items.map(i=><option key={i.id} value={i.id}>{i.label} · {i.context}</option>)}</select></label>
     {searched&&!error&&!items.length&&<p role="status">No matching records.</p>}
   </details>
   <input type="hidden" name="source_id" value={source?chosen?.id??'':''}/><input type="hidden" name="member_id" value={chosen?.member_id??''}/>
 </>;
}
