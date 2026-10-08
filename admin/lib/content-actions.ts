'use server';
import { revalidatePath } from 'next/cache';
import { createAdminClient, createSsrClient } from './supabase/server';
import { requireOperationalActor, operationalResult } from './operational-actions';
import { isUuid } from './inbox-model';
import { workflowFailure, type WorkflowResult } from './workflow-model';

const admins = ['super_admin', 'admin'] as const;
const reviewers = ['super_admin', 'admin', 'moderator'] as const;

const refusals: Record<string, string> = {
  rights_expired: 'An active track needs a rights end date in the future, or none.',
  no_change: 'Nothing changed. The track already has that state and rights date.',
  content_deleted_use_restore_workflow: 'This content was deleted. Restore it from its content page first; media review never undeletes.',
  session_unavailable: 'Your MFA session could not be confirmed. Complete MFA again, then retry.',
  member_not_found: 'No member has that handle or ID.',
  'user not found': 'No member has that handle or ID.',
  'tribe not found': 'This tribe no longer exists. Go back to the list.',
  tribe_not_found: 'This tribe no longer exists. Go back to the list.',
  tribe_not_recoverable: 'The 30-day recovery window has ended, so this tribe can no longer be restored.',
  'reassign the keeper': 'Assign a new keeper before removing this one.',
};

function failure(error: unknown): WorkflowResult {
  const message = error instanceof Error ? error.message : String(error);
  const known = Object.keys(refusals).find(code => message.toLowerCase().includes(code));
  if (known) return { status: 'error', message: refusals[known] };
  return workflowFailure(operationalResult(error));
}

async function call(fn: string, args: Record<string, unknown>) {
  const db = await createSsrClient();
  const { data, error } = await db.rpc(fn, args).abortSignal(AbortSignal.timeout(12_000));
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

function reason(form: FormData): string | null {
  const value = String(form.get('reason') ?? '').trim();
  return value.length >= 3 && value.length <= 500 ? value : null;
}

/** A rights date is a calendar day; it ends at the close of that day in UTC. */
function endOfDayUtc(value: FormDataEntryValue | null): string | null | undefined {
  if (value === null || value === '') return null;
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return undefined;
  const at = new Date(`${value}T23:59:59Z`);
  return Number.isNaN(at.getTime()) ? undefined : at.toISOString();
}

export async function setMusicTrack(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(admins);
    const operation = form.get('operation_id'), track = form.get('track_id');
    const active = form.get('active') === 'true';
    const expires = endOfDayUtc(form.get('rights_expires_on'));
    const why = reason(form);
    if (!isUuid(operation) || !isUuid(track)) return workflowFailure('invalid_input');
    if (expires === undefined) return workflowFailure('invalid_input', 'rights_expires_on');
    if (!why) return workflowFailure('invalid_input', 'reason');
    await call('admin_set_music_track', { p_operation: operation, p_track: track, p_active: active, p_rights_expires_at: expires, p_reason: why });
    revalidatePath('/music');
    revalidatePath(`/music/${track}`);
    return { status: 'success', message: active ? 'Saved. Members can hear this track wherever it is attached.' : 'Taken down. The track is silent everywhere, including on posts that already use it.' };
  } catch (error) { return failure(error); }
}

const MEDIA_STATUS = ['clean', 'sensitive', 'blocked'];
const MEDIA_DONE: Record<string, string> = {
  clean: 'Approved. The image shows normally.',
  sensitive: 'Veiled. Members see it behind a tap-to-reveal cover.',
  blocked: 'Blocked. The image is hidden from members.',
};

export async function setMediaStatus(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(reviewers);
    const kind = String(form.get('kind') ?? ''), id = form.get('id'), status = String(form.get('status') ?? '');
    const why = reason(form);
    if (!['post', 'whisper'].includes(kind) || !isUuid(id) || !MEDIA_STATUS.includes(status)) return workflowFailure('invalid_input');
    if (!why) return workflowFailure('invalid_input', 'reason');
    await call('admin_set_media_status', { p_kind: kind, p_id: id, p_status: status, p_reason: why });
    revalidatePath('/media');
    revalidatePath(`/media/${kind}/${id}`);
    return { status: 'success', message: MEDIA_DONE[status] };
  } catch (error) { return failure(error); }
}

export async function requeueMediaScan(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(reviewers);
    const kind = String(form.get('kind') ?? ''), id = form.get('id');
    const why = reason(form);
    if (!['post', 'whisper'].includes(kind) || !isUuid(id)) return workflowFailure('invalid_input');
    if (!why) return workflowFailure('invalid_input', 'reason');
    const found = await call('admin_requeue_media_scan', { p_kind: kind, p_id: id, p_reason: why });
    if (found === false) return workflowFailure('not_found');
    revalidatePath('/media');
    revalidatePath(`/media/${kind}/${id}`);
    return { status: 'success', message: 'Sent back to the scanner. It is hidden as pending until the new verdict, usually within a minute.' };
  } catch (error) { return failure(error); }
}

/** Accepts a member's handle (with or without @) or their user ID. */
async function memberId(value: FormDataEntryValue | null): Promise<string> {
  const handle = String(value ?? '').trim().replace(/^@/, '');
  const asId: unknown = handle;
  if (isUuid(asId)) return asId;
  if (!/^[a-zA-Z0-9_.-]{2,40}$/.test(handle)) throw new Error('member_not_found');
  const db = await createAdminClient();
  const { data, error } = await db.from('users').select('user_id')
    .or(`anonymous_pseudonym.eq.${handle},username_normalized.eq.${handle.toLowerCase()}`).limit(2);
  if (error) throw new Error(error.message);
  if (!data || data.length !== 1) throw new Error('member_not_found');
  return data[0].user_id as string;
}

function tribeDone(tribe: string, message: string): WorkflowResult {
  revalidatePath('/tribes');
  revalidatePath(`/tribes/${tribe}`);
  return { status: 'success', message };
}

export async function setTribeActive(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(admins);
    const tribe = form.get('tribe_id'), active = form.get('active') === 'true', why = reason(form);
    if (!isUuid(tribe)) return workflowFailure('invalid_input');
    if (!why) return workflowFailure('invalid_input', 'reason');
    await call('admin_set_tribe_active', { p_tribe: tribe, p_active: active, p_reason: why });
    return tribeDone(tribe, active ? 'Tribe reactivated. Members can find and post in it again.' : 'Tribe deactivated. It is hidden and nobody can post in it.');
  } catch (error) { return failure(error); }
}

export async function setTribeFeatured(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(admins);
    const tribe = form.get('tribe_id'), featured = form.get('featured') === 'true', why = reason(form);
    if (!isUuid(tribe)) return workflowFailure('invalid_input');
    if (!why) return workflowFailure('invalid_input', 'reason');
    await call('admin_set_tribe_featured', { p_tribe: tribe, p_featured: featured, p_reason: why });
    return tribeDone(tribe, featured ? 'Featured. It now appears in the featured tribes.' : 'No longer featured.');
  } catch (error) { return failure(error); }
}

export async function setTribeKeeper(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(admins);
    const tribe = form.get('tribe_id'), why = reason(form);
    if (!isUuid(tribe)) return workflowFailure('invalid_input');
    if (!why) return workflowFailure('invalid_input', 'reason');
    const keeper = await memberId(form.get('member'));
    await call('admin_set_tribe_keeper', { p_tribe: tribe, p_new_keeper: keeper, p_reason: why });
    return tribeDone(tribe, 'Keeper changed.');
  } catch (error) { return failure(error); }
}

export async function addTribeMember(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(admins);
    const tribe = form.get('tribe_id'), why = reason(form);
    if (!isUuid(tribe)) return workflowFailure('invalid_input');
    if (!why) return workflowFailure('invalid_input', 'reason');
    const member = await memberId(form.get('member'));
    await call('admin_add_tribe_member', { p_tribe: tribe, p_user: member, p_reason: why });
    return tribeDone(tribe, 'Member added.');
  } catch (error) { return failure(error); }
}

export async function restoreTribe(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(admins);
    const tribe = form.get('tribe_id'), why = reason(form);
    if (!isUuid(tribe)) return workflowFailure('invalid_input');
    if (!why) return workflowFailure('invalid_input', 'reason');
    await call('admin_restore_tribe', { p_tribe_id: tribe, p_reason: why });
    return tribeDone(tribe, 'Tribe restored. Its members and posts are back.');
  } catch (error) { return failure(error); }
}

export async function removeTribeMember(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(admins);
    const tribe = form.get('tribe_id'), why = reason(form);
    if (!isUuid(tribe)) return workflowFailure('invalid_input');
    if (!why) return workflowFailure('invalid_input', 'reason');
    const member = await memberId(form.get('member'));
    await call('admin_remove_tribe_member', { p_tribe: tribe, p_user: member, p_reason: why });
    return tribeDone(tribe, 'Member removed from the tribe.');
  } catch (error) { return failure(error); }
}
