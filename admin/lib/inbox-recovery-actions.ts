'use server';
import { createSsrClient, getRenderStaff } from './supabase/server';
import { requireOperationalActor, operationalResult } from './operational-actions';
import { recoveryUIEnabled } from './inbox-recovery';
import { recoveryReasons } from './inbox-recovery-model';
import { isUuid } from './inbox-model';
import { workflowFailure, type WorkflowResult } from './workflow-model';

export async function retryStaffNotification(form:FormData):Promise<WorkflowResult> {
  try {
    await requireOperationalActor(['super_admin']);
    if(!recoveryUIEnabled((await getRenderStaff())?.role))return workflowFailure('forbidden');
    const operation=form.get('operation_id'),event=form.get('event_id'),reason=form.get('reason_code');
    if(!isUuid(operation)||!isUuid(event))return workflowFailure('invalid_input');
    if(typeof reason!=='string'||!Object.hasOwn(recoveryReasons,reason))return workflowFailure('invalid_input','reason_code');
    const db=await createSsrClient();
    const {error}=await db.rpc('admin_retry_staff_notification',{p_operation:operation,p_event:event,p_reason_code:reason}).abortSignal(AbortSignal.timeout(12_000));
    if(error){
      if(error.code==='PT409')return {status:'error',message:'The worker is busy or this event is no longer failed. Refresh the queue and review its current state before retrying.'};
      if(error.code==='55000')return {status:'error',message:'Notification processing is disabled. Nothing was queued. Ask the rollout owner to review the control state.'};
      return workflowFailure(operationalResult(new Error(error.message)));
    }
    // No route revalidation: retain the receipt even when polling removes the row.
    return {status:'success',message:'Queued again. Delivery is not confirmed. Existing read states are unchanged.'};
  }catch(error){return workflowFailure(operationalResult(error));}
}
