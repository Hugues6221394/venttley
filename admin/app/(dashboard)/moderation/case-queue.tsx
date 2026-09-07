import Link from "next/link";
import { Badge, type Tone } from "@/components/ui/badge";
import { Card } from "@/components/ui/section";
import { EmptyState } from "@/components/ui/empty-state";
import { CheckCircle2, Clock, ShieldAlert, EyeOff, Trash2 } from "@/components/ui/icons";

export type CaseRow = {
  case_id: string;
  target_type: string;
  target_id: string;
  subject_id: string | null;
  subject_pseudonym: string | null;
  status: string;
  severity: string;
  assignee_id: string | null;
  assignee_pseudonym: string | null;
  report_count: number;
  evidence: Record<string, unknown> | null;
  sla_due_at: string | null;
  sla_breached: boolean;
  // NUMERIC over the wire: PostgREST may serialise it as a string to preserve
  // precision, so this is coerced at use rather than assumed to be a number.
  minutes_to_due: number | string | null;
  legal_hold: boolean;
  opened_at: string;
};

const SEVERITY_TONE: Record<string, Tone> = {
  critical: "crisis",
  high: "danger",
  elevated: "warn",
  normal: "info",
  low: "neutral",
};

const TARGET_LABEL: Record<string, string> = {
  post: "Post",
  comment: "Comment",
  whisper: "Whisper",
  story: "Story",
  question: "Question",
  profile: "Profile",
  media: "Media",
  dm_message: "DM",
  tribe_message: "Tribe message",
  chat_room: "Conversation",
  tribe: "Tribe",
};

// Decisions the RPC can actually carry out for a given target. Offering
// "remove content" for a profile would be offering something admin_decide_case
// refuses, so the form doesn't offer it.
const REMOVABLE = new Set([
  "post",
  "comment",
  "whisper",
  "tribe_message",
  "dm_message",
]);

export function CaseQueue({
  rows,
  onClaim,
  onDecide,
  onSetStatus,
  revealHref,
  revealed,
}: {
  rows: CaseRow[];
  onClaim: (fd: FormData) => Promise<void>;
  onDecide: (fd: FormData) => Promise<void>;
  onSetStatus: (fd: FormData) => Promise<void>;
  revealHref: (caseId: string) => string;
  revealed: { caseId: string; body: string } | null;
}) {
  if (rows.length === 0) {
    return (
      <Card padded={false}>
        <div className="px-5 py-12">
          <EmptyState
            icon={<CheckCircle2 size={36} />}
            title="No open cases."
            hint="Every report opens or joins a case. Nothing is waiting on a decision right now."
          />
        </div>
      </Card>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      {rows.map((c) => (
        <CaseCard
          key={c.case_id}
          row={c}
          onClaim={onClaim}
          onDecide={onDecide}
          onSetStatus={onSetStatus}
          revealHref={revealHref}
          revealedBody={revealed?.caseId === c.case_id ? revealed.body : null}
        />
      ))}
    </div>
  );
}

function CaseCard({
  row,
  onClaim,
  onDecide,
  onSetStatus,
  revealHref,
  revealedBody,
}: {
  row: CaseRow;
  onClaim: (fd: FormData) => Promise<void>;
  onDecide: (fd: FormData) => Promise<void>;
  onSetStatus: (fd: FormData) => Promise<void>;
  revealHref: (caseId: string) => string;
  revealedBody: string | null;
}) {
  const resolved = row.status === "resolved";

  return (
    <article className="surface p-5">
      <header className="flex flex-wrap items-center gap-2 mb-3">
        <Badge tone={SEVERITY_TONE[row.severity] ?? "neutral"} icon={<ShieldAlert size={11} />}>
          {row.severity}
        </Badge>
        <span className="pill bg-line text-ink-muted uppercase">
          {TARGET_LABEL[row.target_type] ?? row.target_type}
        </span>
        <Badge tone={resolved ? "ok" : "neutral"}>{row.status.replace(/_/g, " ")}</Badge>
        {row.report_count > 1 && (
          <Badge tone="warn">{row.report_count} reports</Badge>
        )}
        {row.legal_hold && <Badge tone="danger">legal hold</Badge>}
        {row.subject_pseudonym && (
          <span className="text-xs text-ink-muted">@{row.subject_pseudonym}</span>
        )}
        <SlaBadge row={row} />
      </header>

      <Evidence
        targetType={row.target_type}
        evidence={row.evidence}
        revealedBody={revealedBody}
        caseId={row.case_id}
        revealHref={revealHref}
      />

      <p className="text-[11px] text-ink-muted mt-2">
        opened {new Date(row.opened_at).toLocaleString()}
        {row.assignee_pseudonym
          ? ` · assigned to @${row.assignee_pseudonym}`
          : " · unassigned"}
      </p>

      {!resolved && (
        <div className="mt-4 flex flex-col gap-2 pt-4 border-t border-line">
          <div className="flex flex-wrap gap-2">
            {!row.assignee_id && (
              <form action={onClaim}>
                <input type="hidden" name="case_id" value={row.case_id} />
                <button type="submit" className="btn-secondary">
                  Claim
                </button>
              </form>
            )}
            <form action={onSetStatus} className="flex items-center gap-2">
              <input type="hidden" name="case_id" value={row.case_id} />
              <input type="hidden" name="status" value="awaiting_second_review" />
              <button type="submit" className="btn-ghost" title="Send for a second pair of eyes">
                Second review
              </button>
            </form>
            <form action={onSetStatus} className="flex items-center gap-2">
              <input type="hidden" name="case_id" value={row.case_id} />
              <input type="hidden" name="status" value="escalated" />
              <button type="submit" className="btn-ghost">
                Escalate
              </button>
            </form>
          </div>

          {/* One decision form. The decision is recorded AND carried out by
              admin_decide_case in a single transaction. */}
          <form action={onDecide} className="flex flex-wrap items-end gap-2">
            <input type="hidden" name="case_id" value={row.case_id} />
            <div>
              <label className="h-eyebrow block mb-1">Decision</label>
              <select name="decision" className="select" defaultValue="no_action">
                <option value="no_action">No action</option>
                {REMOVABLE.has(row.target_type) && (
                  <option value="content_removed">Remove content</option>
                )}
                <option value="user_warned">Warn member</option>
                {row.subject_id && (
                  <>
                    <option value="user_suspended">Suspend member</option>
                    <option value="user_shadow_restricted">Shadow-restrict member</option>
                    <option value="user_banned">Ban permanently</option>
                  </>
                )}
                <option value="escalated_external">Escalated externally</option>
              </select>
            </div>
            <div>
              <label className="h-eyebrow block mb-1">Policy code</label>
              <input name="policy_code" className="input w-32 font-mono text-xs" placeholder="POL-…" />
            </div>
            <div className="flex-1 min-w-[220px]">
              <label className="h-eyebrow block mb-1">Reason</label>
              {/* admin_decide_case rejects an empty note for any decision that
                  affects a member. The select can't be read from a static
                  form, so rather than let the moderator discover that in an
                  error screen, the note is always required — a recorded
                  no-action decision is worth a sentence too. */}
              <input
                name="note"
                className="input"
                required
                maxLength={1000}
                placeholder="What the member did and which rule it broke"
              />
            </div>
            <button type="submit" className="btn-primary">
              Record decision
            </button>
          </form>
          <p className="text-[11px] text-ink-muted">
            &ldquo;Warn member&rdquo; is recorded but not delivered — there is no
            member-facing notice yet. Suspend, shadow-restrict, ban and remove
            take effect immediately.
          </p>
        </div>
      )}
    </article>
  );
}

function SlaBadge({ row }: { row: CaseRow }) {
  if (row.status === "resolved") return null;
  if (row.sla_breached) {
    return (
      <Badge tone="crisis" icon={<Clock size={11} />}>
        SLA breached
      </Badge>
    );
  }
  const mins = row.minutes_to_due == null ? null : Number(row.minutes_to_due);
  if (mins == null || !Number.isFinite(mins)) return null;
  const label =
    mins < 60 ? `${Math.round(mins)}m left` : `${Math.floor(mins / 60)}h left`;
  return (
    <span className="pill bg-line text-ink-muted inline-flex items-center gap-1">
      <Clock size={11} />
      {label}
    </span>
  );
}

/**
 * The point of the case model: something to decide on. Evidence is the
 * snapshot taken when the case opened, not a live read, so it still shows what
 * was reported after the content has been edited or deleted.
 */
function Evidence({
  targetType,
  evidence,
  revealedBody,
  caseId,
  revealHref,
}: {
  targetType: string;
  evidence: Record<string, unknown> | null;
  revealedBody: string | null;
  caseId: string;
  revealHref: (caseId: string) => string;
}) {
  const e = evidence ?? {};

  if (e.missing) {
    return (
      <p className="text-sm italic text-ink-muted">
        The target was already gone when this case opened.
      </p>
    );
  }

  const text =
    typeof e.content === "string"
      ? e.content
      : typeof e.name === "string"
        ? e.name
        : typeof e.pseudonym === "string"
          ? `@${e.pseudonym}`
          : null;

  return (
    <div className="flex flex-col gap-2">
      {text && (
        <p className="text-sm text-burgundy whitespace-pre-wrap leading-relaxed">
          {text.length > 600 ? text.slice(0, 600).trimEnd() + "…" : text}
        </p>
      )}

      {e.deleted_at != null && (
        <p className="text-[11px] text-ink-muted inline-flex items-center gap-1">
          <Trash2 size={11} /> content already removed — snapshot above is what
          was reported
        </p>
      )}

      {/* Private-message bodies are held separately and read through a
          gated RPC that logs the access, so revealing one is an explicit act
          rather than something that happens by loading the queue. */}
      {targetType === "dm_message" && (
        <div className="surface-flat px-3 py-2">
          {revealedBody != null ? (
            <>
              <p className="text-[11px] text-ink-muted mb-1">
                Message body — this access was logged against your account.
              </p>
              <p className="text-sm text-burgundy whitespace-pre-wrap">
                {revealedBody}
              </p>
            </>
          ) : (
            <div className="flex flex-wrap items-center gap-2">
              <p className="text-xs text-ink-muted flex-1 min-w-[200px] inline-flex items-center gap-1">
                <EyeOff size={12} />
                Private message
                {typeof e.body_length === "number"
                  ? ` · ${e.body_length} characters`
                  : ""}{" "}
                — hidden until you ask for it. Revealing is logged against your
                account.
              </p>
              <Link href={revealHref(caseId)} className="btn-ghost">
                Reveal
              </Link>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
