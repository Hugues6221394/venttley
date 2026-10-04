import { getRenderStaff } from '@/lib/supabase/server';
import { readInboxRecovery, recoveryUIEnabled } from '@/lib/inbox-recovery';
import { recoveryCursor } from '@/lib/inbox-recovery-model';

export const dynamic='force-dynamic';
const reply=(data:unknown,status=200)=>Response.json(data,{status,headers:{'Cache-Control':'private, no-store','Vary':'Cookie'}});
export async function GET(request:Request) {
  try {
    const staff=await getRenderStaff();
    if(staff?.role!=='super_admin')return reply({error:'Current super-admin access required.'},403);
    if(!recoveryUIEnabled(staff.role))return reply({error:'Recovery interface is disabled.'},409);
    const cursor=recoveryCursor(new URL(request.url).searchParams);
    if(cursor===null)return reply({error:'Invalid queue cursor.'},400);
    return reply(await readInboxRecovery(cursor));
  }catch{return reply({error:'Recovery data is unavailable.'},503);}
}
