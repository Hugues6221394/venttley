'use client';

import { useActionState, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { replyToMember } from '@/lib/support-conversation-actions';
import type { WorkflowResult } from '@/lib/workflow-model';
import { Send } from './ui/icons';

const MAX = 2000;

export function SupportReply({ caseId, handle }: { caseId: string; handle: string }) {
  const router = useRouter();
  const form = useRef<HTMLFormElement>(null);
  const [operation, setOperation] = useState(() => crypto.randomUUID());
  const [length, setLength] = useState(0);
  const [result, submit, pending] = useActionState<WorkflowResult | null, FormData>(replyToMember, null);

  // A new operation only after a confirmed send: an uncertain result retries
  // with the same one, so the member can never receive the reply twice.
  useEffect(() => {
    if (result?.status !== 'success') return;
    form.current?.reset();
    setLength(0);
    setOperation(crypto.randomUUID());
    router.refresh();
  }, [result, router]);

  return (
    <form ref={form} action={submit} className="workflow-form support-reply" aria-label="Reply to member">
      <input type="hidden" name="operation_id" value={operation} />
      <input type="hidden" name="case_id" value={caseId} />
      <label className="contact-field">
        <span>Reply to {handle}<small className="tabular">{length}/{MAX}</small></span>
        <textarea name="body" rows={5} maxLength={MAX} required disabled={pending}
          placeholder="Write as the Venttly team. The member sees “Venttly team”, never your name."
          onChange={e => setLength(e.target.value.length)} />
      </label>
      <div className="support-reply-actions">
        <label className="contact-check"><input type="checkbox" name="resolve" value="true" disabled={pending} /> Resolve after sending</label>
        <button type="submit" className="btn-primary" disabled={pending || length === 0}>
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
