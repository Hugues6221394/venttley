"use client";

import { useActionState } from "react";
import { revealEvidence, type RevealState } from "./actions";

const initialState: RevealState = {};

/**
 * The evidence gate for one incident.
 *
 * The material itself is never rendered. `media_url` is shown as a copyable
 * reference, not an <img>: whether this content may be viewed in a browser at
 * all is a question for counsel and trained specialists, and embedding it
 * would answer that question by default — in the affirmative, for anyone who
 * happens to be looking at the operator's screen. The console's own warning
 * banner says not to download or forward it.
 */
export function RevealEvidence({
  incidentId,
  reads,
}: {
  incidentId: string;
  reads: number;
}) {
  const [state, formAction, pending] = useActionState(
    revealEvidence,
    initialState
  );
  const ev = state.evidence;

  return (
    <div className="mt-4 pt-4 border-t border-line">
      {!ev && (
        <form action={formAction} className="flex flex-col gap-2">
          <input type="hidden" name="incident_id" value={incidentId} />
          <label
            htmlFor={`reason-${incidentId}`}
            className="text-xs font-bold text-burgundy"
          >
            Reason for viewing this evidence
          </label>
          <textarea
            id={`reason-${incidentId}`}
            name="reason"
            rows={2}
            required
            minLength={10}
            placeholder="e.g. Preparing the RIB report; verifying the classifier call before escalation"
            className="input text-xs py-2"
          />
          <div className="flex flex-wrap items-center gap-3">
            <button
              className="btn-primary text-xs"
              type="submit"
              disabled={pending}
            >
              {pending ? "Recording…" : "Reveal evidence"}
            </button>
            <span className="text-xs text-ink-muted">
              Your pseudonym, role, reason and the moment are written to the
              child-safety access ledger. It cannot be edited or deleted.
              {reads > 0 && (
                <>
                  {" "}
                  This incident has been opened{" "}
                  <b className="tabular">{reads}</b>{" "}
                  {reads === 1 ? "time" : "times"} already.
                </>
              )}
            </span>
          </div>
          {state.error && (
            <p className="text-xs text-danger" aria-live="polite">
              {state.error}
            </p>
          )}
        </form>
      )}

      {ev && (
        <div className="flex flex-col gap-2">
          <p className="text-xs font-bold text-danger">
            Evidence disclosed — this access is on the record.
          </p>
          <dl className="text-xs text-ink-muted grid grid-cols-[7.5rem_1fr] gap-x-3 gap-y-1">
            <dt className="font-bold">Content ref</dt>
            <dd className="tabular break-all">{ev.content_ref}</dd>
            <dt className="font-bold">Author</dt>
            <dd className="tabular break-all">
              {ev.author_pseudonym ? `@${ev.author_pseudonym}` : "—"}
              {ev.author_id ? ` · ${ev.author_id}` : ""}
            </dd>
            {ev.media_url && (
              <>
                <dt className="font-bold">Media</dt>
                <dd className="tabular break-all">
                  {ev.media_url}
                  <span className="block text-ink-muted italic mt-0.5">
                    Reference only — not rendered here. Do not download,
                    forward, or open outside an approved review process.
                  </span>
                </dd>
              </>
            )}
            <dt className="font-bold">Classifier</dt>
            <dd className="tabular break-all">
              {ev.labels ? JSON.stringify(ev.labels) : "—"}
            </dd>
          </dl>
        </div>
      )}
    </div>
  );
}
