import Link from "next/link";
import { revalidatePath } from "next/cache";
import { rpc } from "@/lib/audit";
import { limitAction } from "@/lib/guard";
import { enumOf, reqStr, uuid } from "@/lib/validate";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { Tabs } from "@/components/ui/tabs";
import { EmptyState } from "@/components/ui/empty-state";
import { Scale, CheckCircle2, Clock, EyeOff } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type AppealRow = {
  appeal_id: string;
  case_id: string | null;
  appellant_id: string;
  appellant_pseudonym: string | null;
  statement: string;
  status: string;
  target_type: string | null;
  original_decision: string | null;
  original_policy: string | null;
  original_note: string | null;
  original_decider: string | null;
  original_decider_pseudonym: string | null;
  decided_at: string | null;
  reviewable_by_me: boolean;
  created_at: string;
};

const DECISION_LABEL: Record<string, string> = {
  content_removed: "Content removed",
  user_warned: "Member warned",
  user_suspended: "Member suspended",
  user_banned: "Banned permanently",
  user_shadow_restricted: "Shadow restricted",
  escalated_external: "Escalated externally",
  no_action: "No action",
};

// What overturning will actually undo, so the reviewer is told the consequence
// before they choose it rather than after. admin_decide_appeal reverses these
// in the same transaction that records the outcome.
const REVERSAL: Record<string, string> = {
  content_removed: "Overturning restores the content.",
  user_suspended: "Overturning lifts the suspension and reinstates the account.",
  user_banned: "Overturning lifts the ban and reinstates the account.",
  user_warned: "Overturning records the reversal; a warning cannot be unsent.",
};

const OUTCOMES = ["upheld", "overturned"] as const;

async function decideAppealAction(formData: FormData) {
  "use server";
  await limitAction("destructive");
  await rpc("admin_decide_appeal", {
    p_appeal: uuid(formData, "appeal_id"),
    p_outcome: enumOf(formData, "outcome", OUTCOMES),
    // Required by the RPC, and not merely for the record: this text is sent to
    // the member as the explanation of the outcome.
    p_note: reqStr(formData, "note", 1000),
  });
  revalidatePath("/appeals");
}

export default async function AppealsPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string }>;
}) {
  const params = await searchParams;
  const tab = params.tab ?? "open";

  const rows =
    (await rpc<AppealRow[]>("admin_appeal_queue", {
      p_status: tab === "all" ? null : tab,
      p_limit: 200,
    })) ?? [];

  const openCount =
    tab === "open"
      ? rows.length
      : ((await rpc<AppealRow[]>("admin_appeal_queue", {
          p_status: "open",
          p_limit: 200,
        })) ?? []).length;

  const tabs = [
    {
      key: "open",
      label: "Open",
      count: openCount,
      tone: openCount > 0 ? ("warn" as const) : ("neutral" as const),
    },
    { key: "overturned", label: "Overturned" },
    { key: "upheld", label: "Upheld" },
    { key: "all", label: "All" },
  ];

  return (
    <div className="flex flex-col gap-6 max-w-[1100px]">
      <PageHeader
        eyebrow="Protect"
        title="Appeals"
        subtitle="A member contesting a decision made about them. Whoever took the original decision cannot review the appeal against it — the queue hides the controls where that applies."
        actions={
          <Link href="/moderation?tab=cases" className="btn-secondary">
            Case queue
          </Link>
        }
      />

      <Tabs tabs={tabs} active={tab} basePath="/appeals" />

      {rows.length === 0 ? (
        <Card padded={false}>
          <div className="px-5 py-12">
            <EmptyState
              icon={<Scale size={34} />}
              title={tab === "open" ? "No open appeals." : "Nothing here."}
              hint="Members are told when a decision affects them, and whether it can be appealed. Appeals arrive here."
            />
          </div>
        </Card>
      ) : (
        <div className="flex flex-col gap-3">
          {rows.map((a) => (
            <AppealCard key={a.appeal_id} row={a} onDecide={decideAppealAction} />
          ))}
        </div>
      )}
    </div>
  );
}

function AppealCard({
  row,
  onDecide,
}: {
  row: AppealRow;
  onDecide: (fd: FormData) => Promise<void>;
}) {
  const open = row.status === "open";
  const decision = row.original_decision ?? "";

  return (
    <article className="surface p-5">
      <header className="flex flex-wrap items-center gap-2 mb-3">
        <Badge tone={open ? "warn" : row.status === "overturned" ? "ok" : "neutral"}>
          {row.status}
        </Badge>
        {row.target_type && (
          <span className="pill bg-line text-ink-muted uppercase">
            {row.target_type}
          </span>
        )}
        {decision && <Badge tone="danger">{DECISION_LABEL[decision] ?? decision}</Badge>}
        {row.original_policy && (
          <span className="pill bg-line text-ink-muted font-mono text-[10px]">
            {row.original_policy}
          </span>
        )}
        <span className="text-xs text-ink-muted flex items-center gap-1 ml-auto">
          <Clock size={12} />
          filed {new Date(row.created_at).toLocaleString()}
        </span>
      </header>

      {/* The member's case, first and largest — it is the thing being reviewed. */}
      <p className="text-sm text-burgundy whitespace-pre-wrap leading-relaxed">
        {row.statement}
      </p>
      <p className="text-[11px] text-ink-muted mt-1">
        — @{row.appellant_pseudonym ?? "unknown"}
      </p>

      {/* What they are contesting, so the reviewer does not have to leave. */}
      <div className="surface-flat mt-3 px-3 py-2">
        <p className="h-eyebrow mb-1">The decision under appeal</p>
        {row.original_note ? (
          <p className="text-sm text-burgundy/90 whitespace-pre-wrap">
            {row.original_note}
          </p>
        ) : (
          <p className="text-sm italic text-ink-muted">
            No reason was recorded with the original decision.
          </p>
        )}
        <p className="text-[11px] text-ink-muted mt-1">
          by @{row.original_decider_pseudonym ?? "unknown"}
          {row.decided_at
            ? ` · ${new Date(row.decided_at).toLocaleString()}`
            : ""}
        </p>
        {row.case_id && (
          <Link
            href={`/moderation?tab=cases_resolved`}
            className="text-[11px] text-berry hover:underline"
          >
            open the case →
          </Link>
        )}
      </div>

      {open &&
        (row.reviewable_by_me ? (
          <form action={onDecide} className="mt-4 flex flex-col gap-2 pt-4 border-t border-line">
            <input type="hidden" name="appeal_id" value={row.appeal_id} />
            {REVERSAL[decision] && (
              <p className="text-[11px] text-ink-muted">{REVERSAL[decision]}</p>
            )}
            <div className="flex flex-wrap items-end gap-2">
              <div>
                <label className="h-eyebrow block mb-1">Outcome</label>
                <select name="outcome" className="select" defaultValue="upheld">
                  <option value="upheld">Uphold the decision</option>
                  <option value="overturned">Overturn it</option>
                </select>
              </div>
              <div className="flex-1 min-w-[240px]">
                <label className="h-eyebrow block mb-1">
                  Reason — the member is sent this
                </label>
                <input
                  name="note"
                  required
                  maxLength={1000}
                  className="input"
                  placeholder="What you concluded, and why"
                />
              </div>
              <button type="submit" className="btn-primary">
                Record outcome
              </button>
            </div>
          </form>
        ) : (
          /* Independence is enforced by admin_decide_appeal, which refuses the
             original decider and the appellant. Showing the controls anyway
             would invite a submission the database will reject, so say why
             instead. */
          <div className="mt-4 pt-4 border-t border-line">
            <p className="text-xs text-ink-muted inline-flex items-center gap-1.5">
              <EyeOff size={13} />
              You cannot review this one — you took the decision being appealed,
              or it is your own appeal. It needs another moderator.
            </p>
          </div>
        ))}

      {!open && (
        <p className="text-[11px] text-ink-muted mt-3 pt-3 border-t border-line inline-flex items-center gap-1.5">
          <CheckCircle2 size={13} />
          {row.status === "overturned"
            ? "Overturned — the decision was reversed and the member told."
            : "Upheld — the decision stands and the member was told."}
        </p>
      )}
    </article>
  );
}
