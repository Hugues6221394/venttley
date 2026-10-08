'use server';
import { revalidatePath } from 'next/cache';
import { createSsrClient, createRequiredAuthAdminClient } from './supabase/server';
import { requireOperationalActor, operationalResult } from './operational-actions';
import { isUuid } from './inbox-model';
import { workflowFailure, type WorkflowResult } from './workflow-model';

const operators = ['super_admin', 'admin'] as const;
const KINDS = ['access', 'deletion', 'correction', 'objection', 'other'];
const BUCKET = 'privacy-exports';
const LINK_SECONDS = 7 * 24 * 60 * 60;

const refusals: Record<string, string> = {
  privacy_conflict: 'This request changed since you opened it, or is no longer open. Refresh and review it.',
  privacy_request_open: 'This member already has an open request of that kind. Work on that one instead.',
  deletion_completes_itself: 'Deletion requests close themselves when the scheduled purge erases the account.',
  email_unavailable: 'This member has no verified email address, so the export cannot be sent. Ask them to verify one in Settings.',
  member_erased: 'The account has already been erased, so there is nothing left to export.',
};

function failure(error: unknown): WorkflowResult {
  const message = error instanceof Error ? error.message : String(error);
  const known = Object.keys(refusals).find(code => message.includes(code));
  if (known) return { status: 'error', message: refusals[known] };
  return workflowFailure(operationalResult(error));
}

function done(member: unknown, message: string): WorkflowResult {
  revalidatePath('/privacy');
  if (isUuid(member)) revalidatePath(`/privacy/requests/${member}`);
  return { status: 'success', message };
}

async function call(fn: string, args: Record<string, unknown>) {
  const db = await createSsrClient();
  const { data, error } = await db.rpc(fn, args).abortSignal(AbortSignal.timeout(20_000));
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

export async function openPrivacyRequest(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(operators);
    const operation = form.get('operation_id'), member = form.get('member_id');
    const kind = String(form.get('kind') ?? ''), note = String(form.get('identity_note') ?? '').trim();
    if (!isUuid(operation) || !isUuid(member)) return workflowFailure('invalid_input');
    if (!KINDS.includes(kind)) return workflowFailure('invalid_input', 'kind');
    if (note.length < 3 || note.length > 500) return workflowFailure('invalid_input', 'identity_note');
    await call('admin_open_privacy_request', { p_operation: operation, p_member: member, p_kind: kind, p_identity_note: note });
    return done(member, 'Request opened. It is due in 30 days.');
  } catch (error) { return failure(error); }
}

const COMMANDS: Record<string, string> = {
  start: 'Marked as in progress and assigned to you.',
  complete: 'Request completed. The outcome is on the record.',
  refuse: 'Request refused. The reason is on the record.',
};

export async function privacyCommand(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(operators);
    const operation = form.get('operation_id'), request = form.get('request_id'), member = form.get('member_id');
    const command = String(form.get('command') ?? ''), version = Number(form.get('version'));
    const note = String(form.get('note') ?? '').trim() || null;
    if (!isUuid(operation) || !isUuid(request) || !Number.isSafeInteger(version) || !(command in COMMANDS)) {
      return workflowFailure('invalid_input');
    }
    if (command !== 'start' && (!note || note.length < 3 || note.length > 1000)) return workflowFailure('invalid_input', 'note');
    await call('admin_privacy_request_command', {
      p_operation: operation, p_request: request, p_version: version, p_command: command, p_note: note,
    });
    return done(member, COMMANDS[command]);
  } catch (error) { return failure(error); }
}

/**
 * The file is named after the operation, so a retried send overwrites the same
 * object and replays the same recorded command instead of mailing a second link.
 */
export async function sendPrivacyExport(form: FormData): Promise<WorkflowResult> {
  let uploaded = false;
  try {
    await requireOperationalActor(operators);
    const operation = form.get('operation_id'), request = form.get('request_id'), member = form.get('member_id');
    const version = Number(form.get('version'));
    if (!isUuid(operation) || !isUuid(request) || !Number.isSafeInteger(version)) return workflowFailure('invalid_input');
    const path = `${request}/${String(operation).toLowerCase()}.json`;

    const exported = await call('admin_privacy_export', { p_request: request });
    const storage = createRequiredAuthAdminClient(AbortSignal.timeout(60_000)).storage.from(BUCKET);
    const file = new Blob([JSON.stringify(exported, null, 2)], { type: 'application/json' });
    const { error: uploadError } = await storage.upload(path, file, { contentType: 'application/json', upsert: true });
    if (uploadError) throw new Error(`upload: ${uploadError.message}`);
    uploaded = true;
    const { data: signed, error: signError } = await storage.createSignedUrl(path, LINK_SECONDS, { download: 'venttly-data.json' });
    if (signError || !signed?.signedUrl) throw new Error(`sign: ${signError?.message ?? 'no link'}`);

    await call('admin_privacy_request_command', {
      p_operation: operation, p_request: request, p_version: version, p_command: 'record_export',
      p_export_path: path, p_link: signed.signedUrl,
    });
    return done(member, 'Export sent. The member has a download link by email, valid for 7 days.');
  } catch (error) {
    // Only a definite refusal proves no link was mailed; after a timeout the file may be what the email points to.
    const message = error instanceof Error ? error.message : '';
    const refused = message.startsWith('admin_privacy_request_command:')
      && /privacy_conflict|email_unavailable|member_erased|invalid_input|rate_limited|not_authorized|aal2|not_found/.test(message);
    if (uploaded && refused) {
      await createRequiredAuthAdminClient().storage.from(BUCKET)
        .remove([`${form.get('request_id')}/${String(form.get('operation_id')).toLowerCase()}.json`]).catch(() => undefined);
    }
    return failure(error);
  }
}

export async function clearPrivacyExport(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(operators);
    const operation = form.get('operation_id'), request = form.get('request_id'), member = form.get('member_id');
    const version = Number(form.get('version'));
    if (!isUuid(operation) || !isUuid(request) || !isUuid(member) || !Number.isSafeInteger(version)) return workflowFailure('invalid_input');
    const current = await call('admin_privacy_member_requests', { p_member: member }) as
      { requests: { request_id: string; export_path: string | null }[] };
    const path = current.requests.find(r => r.request_id === request)?.export_path;
    if (!path) return failure(new Error('privacy_conflict'));
    const { error } = await createRequiredAuthAdminClient(AbortSignal.timeout(20_000)).storage.from(BUCKET).remove([path]);
    if (error) throw new Error(`remove: ${error.message}`);
    await call('admin_privacy_request_command', {
      p_operation: operation, p_request: request, p_version: version, p_command: 'clear_export',
    });
    return done(member, 'Export file deleted. The download link no longer works.');
  } catch (error) { return failure(error); }
}
