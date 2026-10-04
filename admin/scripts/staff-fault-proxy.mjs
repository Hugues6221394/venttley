// Local test transport only. Real session/role/MFA reads always go upstream;
// only the three staff pages' directory/protection/Auth-detail reads are faked.
import { overviewFaultProxy } from './overview-fault-proxy.mjs';

export const staffFixtureId = n => `1a620000-1000-4000-8000-${String(n).padStart(12,'0')}`;
export function staffReadKind(url) {
  if (/^\/auth\/v1\/admin\/users\/[0-9a-f-]{36}$/.test(url.pathname)) return 'auth';
  if (url.pathname !== '/rest/v1/users') return null;
  const fields = url.searchParams.get('select');
  if (fields === 'user_id' && url.searchParams.get('user_role') === 'eq.super_admin' && url.searchParams.get('limit') === '2') return 'protection';
  if (fields === 'user_id,display_name,anonymous_pseudonym,user_role,account_status,deactivated_at,created_at,last_seen_at' && url.searchParams.get('limit') === '26') return 'directory';
  return null;
}

export function staffFaultResponse(url, control) {
  const kind = staffReadKind(url);
  if (!kind) return;
  control.calls[kind]++;
  if (control.mode === `${kind}-failed`) return {status:503,data:{message:'Synthetic staff read unavailable'}};
  if (!control.synthetic) return;
  if (kind === 'protection') return {data:[{user_id:staffFixtureId(90)},{user_id:staffFixtureId(91)}]};
  if (kind === 'auth') {
    const id = url.pathname.split('/').at(-1);
    if (!Array.from({length:30},(_,i)=>staffFixtureId(i+1)).includes(id)) throw Error('Synthetic Auth request outside fixture');
    return {data:{id,email:'sample@example.invalid',email_confirmed_at:'2026-09-28T10:00:00Z',last_sign_in_at:new Date().toISOString(),created_at:'2026-09-28T09:00:00Z',app_metadata:{staff_invite_pending:false}}};
  }
  const params=url.searchParams;
  let rows=Array.from({length:30},(_,i)=>({user_id:staffFixtureId(i+1),display_name:`Sample Operator ${i+1}`,anonymous_pseudonym:`sample_operator_${i+1}`,user_role:'moderator',account_status:'active',deactivated_at:null,created_at:'2026-09-28T09:00:00Z',last_seen_at:new Date().toISOString()}));
  const role=params.getAll('user_role').find(value=>value.startsWith('eq.'))?.slice(3);
  if (role && role !== 'moderator') rows=[];
  if (params.get('or') || params.get('account_status') === 'neq.active') rows=[];
  const after=params.get('user_id');
  if(after)rows=rows.filter(row=>row.user_id>after.slice(3));
  return {data:rows.slice(0,26)};
}

export async function staffFaultProxy(upstream) {
  const control={mode:'normal',synthetic:false,calls:{directory:0,protection:0,auth:0}};
  const proxy=await overviewFaultProxy(upstream,async({url})=>{
    // Delays apply only to staff data, never the authentication gate.
    if(control.mode==='slow' && staffReadKind(url)==='directory')await new Promise(resolve=>setTimeout(resolve,1500));
    return staffFaultResponse(url,control);
  },Number(process.env.ADMIN_STAFF_PROXY_PORT??3115));
  return {...proxy,control};
}
