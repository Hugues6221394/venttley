'use client';

import { useActionState, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { publishBroadcast, withdrawBroadcast } from '@/lib/broadcast-actions';
import type { WorkflowResult } from '@/lib/workflow-model';
import { Megaphone } from './ui/icons';

export type BroadcastTribe = { tribe_id: string; name: string; member_count: number | null };

const URGENCY = [
  ['info', 'Info'],
  ['warning', 'Warning'],
  ['critical', 'Critical'],
  ['crisis', 'Crisis support'],
] as const;

/** `datetime-local` is in the operator's own time zone; the server gets UTC. */
function toIso(local: string): string {
  if (!local) return '';
  const at = new Date(local);
  return Number.isNaN(at.getTime()) ? '' : at.toISOString();
}

function Notice({ result }: { result: WorkflowResult | null }) {
  if (!result) return null;
  const tone = result.status === 'success' ? 'ok' : result.status === 'unknown' ? 'warn' : 'danger';
  return <p role="status" className={`member-notice is-${tone}`}>{result.message}</p>;
}

export function BroadcastComposer({ everyone, tribes }: { everyone: number | null; tribes: BroadcastTribe[] }) {
  const router = useRouter();
  const [operation, setOperation] = useState(() => crypto.randomUUID());
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [urgency, setUrgency] = useState('info');
  const [tribe, setTribe] = useState('');
  const [when, setWhen] = useState<'now' | 'later'>('now');
  const [scheduled, setScheduled] = useState('');
  const [expires, setExpires] = useState('');
  const [result, submit, pending] = useActionState<WorkflowResult | null, FormData>(publishBroadcast, null);

  // A failed or uncertain publish keeps every field and the same operation, so
  // retrying can never send the broadcast twice.
  useEffect(() => {
    if (result?.status !== 'success') return;
    setTitle(''); setBody(''); setUrgency('info'); setTribe(''); setWhen('now'); setScheduled(''); setExpires('');
    setOperation(crypto.randomUUID());
    router.refresh();
  }, [result, router]);

  const picked = tribes.find(t => t.tribe_id === tribe);
  const reach = tribe ? picked?.member_count ?? null : everyone;
  const ready = title.trim() && body.trim() && (when === 'now' || scheduled);

  return (
    <form action={submit} className="workflow-form broadcast-composer" aria-label="New broadcast">
      <input type="hidden" name="operation_id" value={operation} />
      <input type="hidden" name="scheduled_for" value={when === 'later' ? toIso(scheduled) : ''} />
      <input type="hidden" name="expires_at" value={toIso(expires)} />
      <div className="broadcast-grid">
        <label className="contact-field is-wide">
          <span>Title<small className="tabular">{title.length}/120</small></span>
          <input name="title" className="input" maxLength={120} required readOnly={pending} value={title}
            placeholder="What members see first" onChange={e => setTitle(e.target.value)} />
        </label>
        <label className="contact-field">
          <span>Urgency</span>
          <select name="urgency" className="select" value={urgency} disabled={pending} onChange={e => setUrgency(e.target.value)}>
            {URGENCY.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
          </select>
        </label>
      </div>
      <label className="contact-field">
        <span>Message<small className="tabular">{body.length}/1000</small></span>
        <textarea name="body" rows={4} maxLength={1000} required readOnly={pending} value={body}
          placeholder="Keep it short and human. Members see it from the Venttly team."
          onChange={e => setBody(e.target.value)} />
      </label>
      <div className="broadcast-grid">
        <label className="contact-field">
          <span>Audience</span>
          <select name="tribe_id" className="select" value={tribe} disabled={pending} onChange={e => setTribe(e.target.value)}>
            <option value="">Everyone</option>
            {tribes.map(t => <option key={t.tribe_id} value={t.tribe_id}>Tribe: {t.name}</option>)}
          </select>
        </label>
        <fieldset className="contact-field broadcast-when">
          <span>Send</span>
          <div>
            <label className="contact-check"><input type="radio" checked={when === 'now'} disabled={pending} onChange={() => setWhen('now')} /> Now</label>
            <label className="contact-check"><input type="radio" checked={when === 'later'} disabled={pending} onChange={() => setWhen('later')} /> Later</label>
            {when === 'later' && (
              <input type="datetime-local" className="input" aria-label="Send at (your time)" value={scheduled}
                disabled={pending} onChange={e => setScheduled(e.target.value)} />
            )}
          </div>
        </fieldset>
        <label className="contact-field">
          <span>Expires (optional, your time)</span>
          <input type="datetime-local" className="input" value={expires} disabled={pending} onChange={e => setExpires(e.target.value)} />
        </label>
      </div>
      <div className="support-reply-actions">
        <p className="text-xs text-ink-muted">
          {reach === null ? 'Audience size unavailable.' : `Reaches about ${reach.toLocaleString()} member${reach === 1 ? '' : 's'}`}
          {' '}as an in-app notification with the usual generic push. Audited as <code className="font-mono">broadcast.publish</code>.
        </p>
        <button type="submit" className="btn-primary" disabled={pending || !ready}>
          <Megaphone size={14} /> {pending ? 'Sending…' : when === 'later' ? 'Schedule' : 'Publish'}
        </button>
      </div>
      <Notice result={result} />
    </form>
  );
}

export function WithdrawBroadcast({ broadcastId }: { broadcastId: string }) {
  const router = useRouter();
  const [operation] = useState(() => crypto.randomUUID());
  const [confirming, setConfirming] = useState(false);
  const [result, submit, pending] = useActionState<WorkflowResult | null, FormData>(withdrawBroadcast, null);
  useEffect(() => { if (result?.status === 'success') router.refresh(); }, [result, router]);

  if (!confirming) return <button type="button" className="btn-ghost" onClick={() => setConfirming(true)}>Withdraw</button>;
  return (
    <form action={submit} className="broadcast-withdraw">
      <input type="hidden" name="operation_id" value={operation} />
      <input type="hidden" name="broadcast_id" value={broadcastId} />
      <span className="text-xs text-ink-muted">Remove it from every inbox?</span>
      <button type="submit" className="btn-danger" disabled={pending}>{pending ? 'Withdrawing…' : 'Withdraw'}</button>
      <button type="button" className="btn-ghost" disabled={pending} onClick={() => setConfirming(false)}>Keep</button>
      <Notice result={result} />
    </form>
  );
}
