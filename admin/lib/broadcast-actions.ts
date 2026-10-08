'use server';
import { revalidatePath } from 'next/cache';
import { createSsrClient } from './supabase/server';
import { requireOperationalActor, operationalResult } from './operational-actions';
import { isUuid } from './inbox-model';
import { workflowFailure, type WorkflowResult } from './workflow-model';

const publishers = ['super_admin', 'admin'] as const;
const URGENCIES = ['info', 'warning', 'critical', 'crisis'];

function isoOrNull(value: FormDataEntryValue | null): string | null | undefined {
  if (value === null || value === '') return null;
  if (typeof value !== 'string') return undefined;
  const at = new Date(value);
  return Number.isNaN(at.getTime()) ? undefined : at.toISOString();
}

const refusals: Record<string, string> = {
  invalid_schedule: 'Pick a send time in the future, at most 30 days ahead.',
  invalid_expiry: 'The expiry must be at least 10 minutes after sending, and at most 30 days.',
  tribe_not_found: 'That tribe is no longer active. Pick another audience.',
  invalid_broadcast_payload: 'Check the title and message: no leading or trailing spaces, title up to 120 characters, message up to 1,000.',
  broadcast_approval_required: 'Two-person approval is switched on: request approval for this broadcast instead.',
};

export async function publishBroadcast(_previous: WorkflowResult | null, form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(publishers);
    const operation = form.get('operation_id');
    const title = String(form.get('title') ?? '').trim();
    const body = String(form.get('body') ?? '').trim();
    const urgency = String(form.get('urgency') ?? '');
    const tribe = form.get('tribe_id') || null;
    const scheduled = isoOrNull(form.get('scheduled_for'));
    const expires = isoOrNull(form.get('expires_at'));
    if (!isUuid(operation)) return workflowFailure('invalid_input');
    if (title.length < 1 || title.length > 120) return workflowFailure('invalid_input', 'title');
    if (body.length < 1 || body.length > 1000) return workflowFailure('invalid_input', 'body');
    if (!URGENCIES.includes(urgency)) return workflowFailure('invalid_input', 'urgency');
    if (tribe !== null && !isUuid(tribe)) return workflowFailure('invalid_input', 'tribe_id');
    if (scheduled === undefined) return workflowFailure('invalid_input', 'scheduled_for');
    if (expires === undefined) return workflowFailure('invalid_input', 'expires_at');
    const db = await createSsrClient();
    const { error } = await db.rpc('admin_publish_broadcast', {
      p_operation: operation, p_title: title, p_body: body, p_urgency: urgency,
      p_tribe: tribe, p_scheduled_for: scheduled, p_expires_at: expires,
    }).abortSignal(AbortSignal.timeout(12_000));
    if (error) {
      const known = Object.keys(refusals).find(code => error.message.includes(code));
      if (known) return { status: 'error', message: refusals[known] };
      return workflowFailure(operationalResult(new Error(error.message)));
    }
    revalidatePath('/broadcasts');
    return {
      status: 'success',
      message: scheduled
        ? 'Scheduled. Delivery starts at the chosen time, in batches of about a thousand members a minute.'
        : 'Published. Members receive it as a notification over the next few minutes, with a push to devices that allow it.',
    };
  } catch (error) { return workflowFailure(operationalResult(error)); }
}

export async function withdrawBroadcast(_previous: WorkflowResult | null, form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(publishers);
    const operation = form.get('operation_id'), broadcast = form.get('broadcast_id');
    if (!isUuid(operation) || !isUuid(broadcast)) return workflowFailure('invalid_input');
    const db = await createSsrClient();
    const { error } = await db.rpc('admin_withdraw_broadcast', { p_operation: operation, p_broadcast: broadcast })
      .abortSignal(AbortSignal.timeout(12_000));
    if (error) return workflowFailure(operationalResult(new Error(error.message)));
    revalidatePath('/broadcasts');
    return { status: 'success', message: 'Withdrawn. Delivery stopped, and it is being removed from the inboxes it reached.' };
  } catch (error) { return workflowFailure(operationalResult(error)); }
}
