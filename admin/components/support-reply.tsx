'use client';

import { useActionState, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { replyToMember } from '@/lib/support-conversation-actions';
import type { WorkflowResult } from '@/lib/workflow-model';
import { Send } from './ui/icons';

const MAX = 2000;

export function SupportReply({ caseId, handle }: { caseId: string; handle: string }) {
  const router = useRouter();
  const [operation, setOperation] = useState(() => crypto.randomUUID());
  const [body, setBody] = useState('');
  const [resolve, setResolve] = useState(false);
  const [result, submit, pending] = useActionState<WorkflowResult | null, FormData>(replyToMember, null);

  // Cleared, with a new operation, only after a confirmed send: a failed or
  // uncertain send keeps the text and retries with the same operation, so the
  // member can never receive the reply twice.
  useEffect(() => {
    if (result?.status !== 'success') return;
    setBody('');
    setResolve(false);
    setOperation(crypto.randomUUID());
    router.refresh();
  }, [result, router]);

  return (
    <form action={submit} className="workflow-form support-reply" aria-label="Reply to member">
      <input type="hidden" name="operation_id" value={operation} />
      <input type="hidden" name="case_id" value={caseId} />
      <label className="contact-field">
        <span>Reply to {handle}<small className="tabular">{body.length}/{MAX}</small></span>
        <textarea name="body" rows={5} maxLength={MAX} required readOnly={pending} value={body}
          placeholder="Write as the Venttly team. The member sees “Venttly team”, never your name."
          onChange={e => setBody(e.target.value)} />
      </label>
      <div className="support-reply-actions">
        <label className="contact-check">
          <input type="checkbox" name="resolve" value="true" checked={resolve} disabled={pending} onChange={e => setResolve(e.target.checked)} />
          Resolve after sending
        </label>
        <button type="submit" className="btn-primary" disabled={pending || body.trim().length === 0}>
          <Send size={15} /> {pending ? 'Sending…' : 'Send reply'}
        </button>
      </div>
      {result && (
        <p role="status" className={`member-notice is-${result.status === 'success' ? 'ok' : result.status === 'unknown' ? 'warn' : 'danger'}`}>
          {result.message}
        </p>
      )}
    </form>
  );
}
