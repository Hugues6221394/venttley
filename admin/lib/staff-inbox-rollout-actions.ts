'use server';
import { revalidatePath } from 'next/cache';
import { createSsrClient } from './supabase/server';
import { requireOperationalActor, operationalResult } from './operational-actions';
import { isUuid } from './inbox-model';
import { workflowFailure, type WorkflowResult } from './workflow-model';
import { inboxAudiences } from './staff-inbox-rollout';

export async function configureStaffInbox(form:FormData):Promise<WorkflowResult> {
  try {
    await requireOperationalActor(['super_admin']);
    const operation=form.get('operation_id'),enabled=form.get('enabled'),audience=form.get('audience');
    if(!isUuid(operation))return workflowFailure('invalid_input');
    if(enabled!=='true'&&enabled!=='false')return workflowFailure('invalid_input','enabled');
    if(typeof audience!=='string'||!Object.hasOwn(inboxAudiences,audience))return workflowFailure('invalid_input','audience');
    const db=await createSsrClient();
    const {error}=await db.rpc('admin_configure_staff_inbox',{
      p_operation:operation,p_enabled:enabled==='true',p_roles:[...inboxAudiences[audience as keyof typeof inboxAudiences].roles],
    }).abortSignal(AbortSignal.timeout(12_000));
    if(error)return workflowFailure(operationalResult(new Error(error.message)));
    revalidatePath('/system');
    return {status:'success',message:enabled==='true'
      ?'Staff notifications are on for the selected roles. New events are delivered by the next worker run (within a minute).'
      :'Staff notifications are off. Existing notices are kept; no new ones are produced.'};
  }catch(error){return workflowFailure(operationalResult(error));}
}
