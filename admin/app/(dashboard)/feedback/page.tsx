import { revalidatePath } from "next/cache";
import { rpc } from "@/lib/audit";
import { limitAction } from "@/lib/guard";
import { enumOf, optStr, uuid } from "@/lib/validate";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { Tabs } from "@/components/ui/tabs";
import { EmptyState } from "@/components/ui/empty-state";
import { Clock } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type FeedbackRow = {
  report_id: string;
  kind: "bug" | "suggestion";
  title: string;
  detail: string;
  screen: string | null;
  app_version: string | null;
  platform: string | null;
  device: string | null;
  status: string;
  staff_note: string | null;
  reporter_pseudonym: string | null;
  reviewed_at: string | null;
  created_at: string;
};

// What each status means to the person who sent it — the app shows these words
// back to them, so the reviewer should be choosing a message, not a label.
const STATUS_MEANING: Record<string, string> = {
  new: "Waiting — nobody has looked yet.",
  triaged: 'They are told "read by the team".',
  planned: "They are told it is planned.",
  fixed: "They are told it is fixed.",
  declined: "They are told it is not planned.",
};

const STATUSES = ["new", "triaged", "planned", "fixed", "declined"] as const;

const TONE: Record<string, "warn" | "ok" | "neutral" | "danger"> = {
  new: "warn",
  triaged: "neutral",
  planned: "neutral",
  fixed: "ok",
  declined: "danger",
};

async function triageAction(formData: FormData) {
  "use server";
  await limitAction("bulk");
  await rpc("admin_triage_feedback", {
    p_report: uuid(formData, "report_id"),
    p_status: enumOf(formData, "status", STATUSES),
    // Optional, and shown to the reporter verbatim when present. It is the
    // only reply anybody gets, which is why it is a free field rather than a
    // canned line chosen from a list.
    p_note: optStr(formData, "note", 2000),
  });
  revalidatePath("/feedback");
}

export default async function FeedbackPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; kind?: string }>;
}) {
  const params = await searchParams;
  const tab = params.tab ?? "new";
  const kind = params.kind ?? null;

  const rows =
    (await rpc<FeedbackRow[]>("admin_feedback_queue", {
      p_status: tab === "all" ? null : tab,
      p_kind: kind,
      p_limit: 200,
    })) ?? [];

  const newCount =
    tab === "new"
      ? rows.length
      : ((await rpc<FeedbackRow[]>("admin_feedback_queue", {
          p_status: "new",
          p_limit: 200,
        })) ?? []).length;

  const tabs = [
    {
      key: "new",
      label: "New",
      count: newCount,
      tone: newCount > 0 ? ("warn" as const) : ("neutral" as const),
    },
    { key: "triaged", label: "Triaged" },
    { key: "planned", label: "Planned" },
    { key: "fixed", label: "Fixed" },
    { key: "declined", label: "Not planned" },
    { key: "all", label: "All" },
  ];

  return (
    <div className="flex flex-col gap-6 max-w-[1100px]">
      <PageHeader
        eyebrow="Build"
        title="Bugs and suggestions"
        subtitle="Reported from inside the app. Oldest first within a status, so a report that has been waiting three weeks does not sink under this morning's."
      />

      <Tabs tabs={tabs} active={tab} basePath="/feedback" />

      {rows.length === 0 ? (
        <Card padded={false}>
          <div className="px-5 py-12">
            <EmptyState
              title={tab === "new" ? "Nothing new." : "Nothing here."}
              hint="Members report bugs and suggest features from Settings. They arrive here."
            />
          </div>
        </Card>
      ) : (
        <div className="flex flex-col gap-3">
          {rows.map((r) => (
            <FeedbackCard key={r.report_id} row={r} onTriage={triageAction} />
          ))}
        </div>
      )}
    </div>
  );
}

function FeedbackCard({
  row,
  onTriage,
}: {
  row: FeedbackRow;
  onTriage: (fd: FormData) => Promise<void>;
}) {
  // The build and device, gathered by the app rather than typed by the
  // reporter. A bug report you cannot reproduce is barely a bug report.
  const context = [row.app_version, row.platform, row.device, row.screen]
    .filter(Boolean)
    .join(" · ");

  return (
    <article className="surface p-5">
      <header className="flex flex-wrap items-center gap-2 mb-3">
        <Badge tone={TONE[row.status] ?? "neutral"}>{row.status}</Badge>
        <span className="pill bg-line text-ink-muted uppercase">
          {row.kind === "bug" ? "bug" : "suggestion"}
        </span>
        <span className="text-xs text-ink-muted flex items-center gap-1 ml-auto">
          <Clock size={12} />
          {new Date(row.created_at).toLocaleString()}
        </span>
      </header>

      <h3 className="text-sm font-bold text-burgundy">{row.title}</h3>
      <p className="text-sm text-burgundy/90 whitespace-pre-wrap leading-relaxed mt-1">
        {row.detail}
      </p>
      <p className="text-[11px] text-ink-muted mt-1">
        — @{row.reporter_pseudonym ?? "a deleted account"}
      </p>

      {context && (
        <p className="text-[11px] text-ink-muted font-mono mt-2">{context}</p>
      )}

      {row.staff_note && (
        <div className="surface-flat mt-3 px-3 py-2">
          <p className="h-eyebrow mb-1">Sent back to them</p>
          <p className="text-sm text-burgundy/90 whitespace-pre-wrap">
            {row.staff_note}
          </p>
        </div>
      )}

      <form action={onTriage} className="mt-4 flex flex-wrap items-end gap-2">
        <input type="hidden" name="report_id" value={row.report_id} />
        <label className="flex flex-col gap-1">
          <span className="h-eyebrow">Status</span>
          <select name="status" defaultValue={row.status} className="input">
            {STATUSES.map((s) => (
              <option key={s} value={s}>
                {s} — {STATUS_MEANING[s]}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1 flex-1 min-w-[240px]">
          <span className="h-eyebrow">Reply to the reporter (optional)</span>
          <input
            name="note"
            maxLength={2000}
            defaultValue={row.staff_note ?? ""}
            placeholder="Shown to them exactly as written"
            className="input"
          />
        </label>
        <button type="submit" className="btn-primary">
          Save
        </button>
      </form>
    </article>
  );
}
