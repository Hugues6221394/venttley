'use server';
import { revalidatePath } from 'next/cache';
import { createSsrClient } from './supabase/server';
import { requireOperationalActor, operationalResult } from './operational-actions';
import { isUuid } from './inbox-model';
import { workflowFailure, type WorkflowResult } from './workflow-model';

/** Each switch maps to its own audited, MFA-gated configure RPC; nothing else is reachable from here. */
const SWITCHES = {
  inbox_operations: { fn: 'admin_configure_staff_inbox_operations', fields: { p_moderation: 'moderation', p_retention: 'retention' } },
  inbox_sources: { fn: 'admin_configure_staff_inbox_sources', fields: { p_jobs: 'jobs', p_reports: 'reports' } },
  governance_notices: { fn: 'admin_configure_governance_notices', fields: { p_enabled: 'enabled' } },
  access_reviews: { fn: 'admin_configure_access_reviews', fields: { p_enabled: 'enabled' } },
  invitation_ledger: { fn: 'admin_configure_invitation_ledger', fields: { p_enabled: 'enabled' } },
} as const;

export async function configureControlSwitch(form: FormData): Promise<WorkflowResult> {
  try {
    await requireOperationalActor(['super_admin']);
    const operation = form.get('operation_id'), key = String(form.get('switch') ?? '');
    if (!isUuid(operation) || !Object.hasOwn(SWITCHES, key)) return workflowFailure('invalid_input');
    const target = SWITCHES[key as keyof typeof SWITCHES];
    const args: Record<string, unknown> = { p_operation: operation };
    for (const [param, field] of Object.entries(target.fields)) {
      const value = form.get(field);
      if (value !== 'true' && value !== 'false') return workflowFailure('invalid_input', field);
      args[param] = value === 'true';
    }
    const db = await createSsrClient();
    const { error } = await db.rpc(target.fn, args).abortSignal(AbortSignal.timeout(12_000));
    if (error) return workflowFailure(operationalResult(new Error(error.message)));
    revalidatePath('/system');
    return { status: 'success', message: 'Saved and audit-logged. Refresh to see the new state.' };
  } catch (error) { return workflowFailure(operationalResult(error)); }
}
