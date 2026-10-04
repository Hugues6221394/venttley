// Test process only; never imported by the application. Synthetic reads support
// design review without sending any real content to a design provider.
import { overviewFaultProxy } from './overview-fault-proxy.mjs';
export async function workflowFaultProxy(upstream) {
  const control={mode:'normal',fixtures:{}};
  const proxy=await overviewFaultProxy(upstream,async({url})=>{
    const fn=url.pathname.split('/').at(-1);
    if(control.mode==='failed'&&fn==='admin_support_work_queue')return {status:503,data:{message:'Synthetic unavailable queue'}};
    if(control.mode==='slow'&&fn==='admin_update_support_case_checked')await new Promise(r=>setTimeout(r,1800));
    if(control.mode==='synthetic'&&Object.hasOwn(control.fixtures,fn))return {data:control.fixtures[fn]};
  },Number(process.env.ADMIN_WORKFLOW_PROXY_PORT??3114));
  return {...proxy,control};
}
