'use server';
import { revalidatePath } from 'next/cache';
import { createSsrClient } from './supabase/server';
import { requireOperationalActor, operationalResult } from './operational-actions';
import { isUuid } from './inbox-model';
import { workflowFailure, type WorkflowResult } from './workflow-model';

const senders = ['super_admin', 'admin', 'support'] as const;
const wardens = ['super_admin', 'admin'] as const;

function text(form: FormData, name: string, min: number, max: number): string | null {
  const value = form.get(name);
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length >= min && trimmed.length <= max ? trimmed : null;
}

async function send(rpc: string, args: Record<string, unknown>, member: string, success: string): Promise<WorkflowResult> {
  const db = await createSsrClient();
  const { error } = await db.rpc(rpc, args).abortSignal(AbortSignal.timeout(12_000));
  if (error) {
    if (error.message.includes('email_unavailable')) {
      return { status: 'error', message: 'This member has no verified email address. Send an in-app message instead.' };
    }
    return workflowFailure(operationalResult(new Error(error.message)));
  }
  revalidatePath(`/users/${member}`);
  return { status: 'success', message: success };
}

export async function messageMember(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(senders);
    const operation = form.get('operation_id'), member = form.get('member_id');
    if (!isUuid(operation) || !isUuid(member)) return workflowFailure('invalid_input');
    const subject = text(form, 'subject', 3, 80);
    if (!subject) return workflowFailure('invalid_input', 'subject');
    const body = text(form, 'body', 10, 1000);
    if (!body) return workflowFailure('invalid_input', 'body');
    return await send('admin_message_member', { p_operation: operation, p_member: member, p_subject: subject, p_body: body }, member,
      'Message delivered to the member’s notifications, with a push notification that does not show the text.');
  } catch (error) { return workflowFailure(operationalResult(error)); }
}

export async function warnMember(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(wardens);
    const operation = form.get('operation_id'), member = form.get('member_id'), appealable = form.get('appealable') ?? 'false';
    if (!isUuid(operation) || !isUuid(member)) return workflowFailure('invalid_input');
    const policyRaw = form.get('policy');
    const policy = typeof policyRaw === 'string' ? policyRaw.trim() : '';
    if (policy.length > 40) return workflowFailure('invalid_input', 'policy');
    const reason = text(form, 'reason', 10, 1000);
    if (!reason) return workflowFailure('invalid_input', 'reason');
    if (appealable !== 'true' && appealable !== 'false') return workflowFailure('invalid_input', 'appealable');
    return await send('admin_warn_member', { p_operation: operation, p_member: member, p_policy: policy || null, p_reason: reason, p_appealable: appealable === 'true' }, member,
      'Warning issued. The member sees it under Appeals & warnings and it is recorded on their profile.');
  } catch (error) { return workflowFailure(operationalResult(error)); }
}

export async function emailMember(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(senders);
    const operation = form.get('operation_id'), member = form.get('member_id');
    if (!isUuid(operation) || !isUuid(member)) return workflowFailure('invalid_input');
    const subject = text(form, 'subject', 3, 80);
    if (!subject) return workflowFailure('invalid_input', 'subject');
    const body = text(form, 'body', 10, 1000);
    if (!body) return workflowFailure('invalid_input', 'body');
    return await send('admin_email_member', { p_operation: operation, p_member: member, p_subject: subject, p_body: body }, member,
      'Email queued. Delivery status appears in the history below within a minute.');
  } catch (error) { return workflowFailure(operationalResult(error)); }
}
