'use client';

import { useState } from 'react';
import { WorkflowForm } from './workflows/workflow-form';
import { emailMember, messageMember, warnMember } from '@/lib/member-contact-actions';

export type ContactChannel = 'message' | 'warning' | 'email';
export type ContactOptions = { email_available: boolean; email_hint: string | null; can_warn: boolean; is_self: boolean };

function Counted({ name, label, max, rows, placeholder }: { name: string; label: string; max: number; rows?: number; placeholder: string }) {
  const [length, setLength] = useState(0);
  const props = { name, maxLength: max, required: true, placeholder, onChange: (e: { target: { value: string } }) => setLength(e.target.value.length) };
  return (
    <label className="contact-field">
      <span>{label}<small className="tabular">{length}/{max}</small></span>
      {rows ? <textarea rows={rows} {...props} /> : <input type="text" {...props} />}
    </label>
  );
}

export function MemberContact({ memberId, handle, options, initial }: {
  memberId: string; handle: string; options: ContactOptions; initial: ContactChannel;
}) {
  const [channel, setChannel] = useState<ContactChannel>(initial === 'warning' && !options.can_warn ? 'message' : initial);
  const [operations] = useState(() => ({ message: crypto.randomUUID(), warning: crypto.randomUUID(), email: crypto.randomUUID() }));
  if (options.is_self) return <p className="operator-note">You cannot contact your own account.</p>;
  const channels: { id: ContactChannel; label: string; disabled?: string }[] = [
    { id: 'message', label: 'In-app message' },
    { id: 'warning', label: 'Formal warning', disabled: options.can_warn ? undefined : 'Only admins and super admins can issue warnings.' },
    { id: 'email', label: 'Email', disabled: options.email_available ? undefined : 'No verified email address on this account.' },
  ];
  return (
    <div className="contact-composer">
      <div className="segmented" role="tablist" aria-label="Channel">
        {channels.map(c => (
          <button key={c.id} type="button" role="tab" aria-selected={channel === c.id} disabled={Boolean(c.disabled)} title={c.disabled}
            onClick={() => setChannel(c.id)}>{c.label}</button>
        ))}
      </div>

      {channel === 'message' && (
        <div key="message">
          <p className="contact-explainer">Appears in {handle}’s notifications as a message from the Venttly team. The push notification is generic and never shows this text.</p>
          <WorkflowForm label="Send message" action={messageMember}
            confirmation={`Send this in-app message to ${handle}? It is recorded on their profile and in the audit log.`}>
            <input type="hidden" name="operation_id" value={operations.message} />
            <input type="hidden" name="member_id" value={memberId} />
            <Counted name="subject" label="Subject" max={80} placeholder="e.g. Checking in after your report" />
            <Counted name="body" label="Message" max={1000} rows={6} placeholder="Write as the Venttly team. Be specific and kind." />
          </WorkflowForm>
        </div>
      )}

      {channel === 'warning' && options.can_warn && (
        <div key="warning">
          <p className="contact-explainer">A formal warning does not restrict the account. {handle} sees it under Appeals &amp; warnings, and an appeal is reviewed by someone other than you.</p>
          <WorkflowForm label="Issue warning" action={warnMember}
            confirmation={`Issue a formal warning to ${handle}? It is permanent on their record and audit-logged.`}>
            <input type="hidden" name="operation_id" value={operations.warning} />
            <input type="hidden" name="member_id" value={memberId} />
            <label className="contact-field"><span>Policy code <small>optional</small></span>
              <input type="text" name="policy" maxLength={40} placeholder="e.g. COMMUNITY-3" />
            </label>
            <Counted name="reason" label="What the member did, written for them to read" max={1000} rows={5} placeholder="This is the only explanation they receive, and what an appeal argues with." />
            <label className="contact-check"><input type="checkbox" name="appealable" value="true" defaultChecked />
              Member may appeal within 30 days</label>
          </WorkflowForm>
        </div>
      )}

      {channel === 'email' && options.email_available && (
        <div key="email">
          <p className="contact-explainer">Sent to {options.email_hint} from the Venttly address. Use email only when an in-app message is not enough.</p>
          <WorkflowForm label="Send email" action={emailMember}
            confirmation={`Email ${handle} at ${options.email_hint}? It is recorded on their profile and in the audit log.`}>
            <input type="hidden" name="operation_id" value={operations.email} />
            <input type="hidden" name="member_id" value={memberId} />
            <Counted name="subject" label="Subject" max={80} placeholder="Appears after “Venttly:” in the inbox" />
            <Counted name="body" label="Email body" max={1000} rows={7} placeholder="Plain text. Blank lines start new paragraphs." />
          </WorkflowForm>
        </div>
      )}
    </div>
  );
}
