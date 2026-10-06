'use server';
import { revalidatePath } from 'next/cache';
import { createSsrClient } from './supabase/server';
import { requireOperationalActor, operationalResult } from './operational-actions';
import { isUuid } from './inbox-model';
import { workflowFailure, type WorkflowResult } from './workflow-model';

const responders = ['super_admin', 'admin', 'support'] as const;

export async function replyToMember(_previous: WorkflowResult | null, form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(responders);
    const operation = form.get('operation_id'), supportCase = form.get('case_id'), raw = form.get('body');
    if (!isUuid(operation) || !isUuid(supportCase)) return workflowFailure('invalid_input');
    const body = typeof raw === 'string' ? raw.trim() : '';
    if (body.length < 1 || body.length > 2000) return workflowFailure('invalid_input', 'body');
    const resolve = form.get('resolve') === 'true';
    const db = await createSsrClient();
    const { error } = await db.rpc('admin_reply_support', { p_operation: operation, p_case: supportCase, p_body: body, p_resolve: resolve })
      .abortSignal(AbortSignal.timeout(12_000));
    if (error) {
      if (error.message.includes('closed_support_case')) return { status: 'error', message: 'This case is closed. Reopen it from the support queue before replying.' };
      return workflowFailure(operationalResult(new Error(error.message)));
    }
    revalidatePath(`/support/cases/${supportCase}`);
    return { status: 'success', message: resolve ? 'Reply sent and the case is resolved. The member can still answer for 30 days.' : 'Reply sent. The member gets a notification; the case now waits on them.' };
  } catch (error) { return workflowFailure(operationalResult(error)); }
}
