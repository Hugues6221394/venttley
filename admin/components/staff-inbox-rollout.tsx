'use client';

import { useState } from 'react';
import { WorkflowForm } from './workflows/workflow-form';
import { configureStaffInbox } from '@/lib/staff-inbox-rollout-actions';
import { audienceFor, inboxAudiences } from '@/lib/staff-inbox-rollout';

export type InboxRolloutHealth = {
  enabled: boolean;
  audience_roles: string[];
  worker_at: string | null;
  worker_stale: boolean;
  pending: number;
};

const when = (at: string | null) => at ? new Date(at).toISOString().replace('T', ' ').slice(0, 19) + ' UTC' : 'never';

export function StaffInboxRollout({ health }: { health: InboxRolloutHealth | null }) {
  const [operation] = useState(() => crypto.randomUUID());
  if (!health) {
    return <p role="status" className="operator-unavailable">Notification rollout state is unavailable. Nothing is assumed on or off.</p>;
  }
  const next = !health.enabled;
  const current = audienceFor(health.audience_roles);
  return (
    <div className="flex flex-col gap-4" data-inbox-rollout={health.enabled ? 'on' : 'off'}>
      <dl className="grid grid-cols-2 md:grid-cols-4 gap-3 text-sm">
        <div><dt className="text-ink-muted text-xs">Status</dt><dd className="font-semibold">{health.enabled ? 'On' : 'Off'}</dd></div>
        <div><dt className="text-ink-muted text-xs">Audience</dt><dd>{current ? inboxAudiences[current].label : health.audience_roles.join(', ')}</dd></div>
        <div><dt className="text-ink-muted text-xs">Worker last ran</dt><dd>{when(health.worker_at)}{health.enabled && health.worker_stale ? ' · stale' : ''}</dd></div>
        <div><dt className="text-ink-muted text-xs">Pending events</dt><dd className="tabular">{health.pending.toLocaleString('en-US')}</dd></div>
      </dl>
      <WorkflowForm
        label={next ? 'Turn on staff notifications' : 'Turn off staff notifications'}
        confirmation={next
          ? 'Start producing staff notifications and queue badges for the selected roles? MFA is checked again and the change is audit-logged.'
          : 'Stop producing new staff notifications? Existing notices stay readable. MFA is checked again and the change is audit-logged.'}
        action={configureStaffInbox}
      >
        <input type="hidden" name="operation_id" value={operation} />
        <input type="hidden" name="enabled" value={String(next)} />
        <label className="flex flex-col gap-1 text-sm">Who receives notifications
          <select name="audience" defaultValue={current ?? 'super_admin'} required>
            {Object.entries(inboxAudiences).map(([value, preset]) => <option key={value} value={value}>{preset.label}</option>)}
          </select>
        </label>
      </WorkflowForm>
    </div>
  );
}
