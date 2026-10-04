import 'server-only';
import { requireOperationalActor, operationalResult } from './operational-actions';
import { InvalidInput } from './validate';
import { workflowUIEnabled } from './workflows';
import { workflowFailure, type WorkflowResult } from './workflow-model';

export async function runWorkflow(roles:readonly string[],operation:()=>Promise<unknown>,message:string):Promise<WorkflowResult> {
  try {
    await requireOperationalActor(roles);
    if(!await workflowUIEnabled())return workflowFailure('forbidden');
    await operation();
    // These routes are force-dynamic. Immediate path revalidation can remove a
    // resolved queue row and unmount its drawer before the success is announced.
    // WorkflowForm refreshes attention separately and offers an explicit record
    // refresh; keep the confirmed outcome visible until that operator action.
    return {status:'success',message};
  }catch(error){
    if(error instanceof InvalidInput)return workflowFailure('invalid_input',error.message.split(':')[0]);
    if(error instanceof Error&&error.message.includes('workflow_conflict'))return workflowFailure('conflict');
    return workflowFailure(operationalResult(error));
  }
}
