import Link from "next/link";
import { notFound } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createAdminClient, createSsrClient } from "@/lib/supabase/server";
import { rpc } from "@/lib/audit";
import { enumOf, reqStr, uuid } from "@/lib/validate";
import { PageHeader } from "@/components/ui/page-header";
import { Card, Row } from "@/components/ui/section";
import { Badge, type Tone } from "@/components/ui/badge";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import {
  ChevronLeft,
  Clock,
  FileText,
  Lock,
  ShieldAlert,
} from "@/components/ui/icons";

export const dynamic = "force-dynamic";

const OPEN_STATUSES = [
  "open",
  "in_review",
  "awaiting_second_review",
  "escalated",
  "reopened",
] as const;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type CaseRecord = {
  case_id: string;
  target_type: string;
  target_id: string;
  subject_id: string | null;
  status: string;
  severity: string;
  policy_code: string | null;
  assignee_id: string | null;
  assigned_at: string | null;
  decision: string | null;
  decided_by: string | null;
  decided_at: string | null;
  decision_note: string | null;
  evidence: Record<string, unknown> | null;
  evidence_hash: string;
  evidence_captured_at: string;
  sla_due_at: string | null;
  sla_breached_at: string | null;
  first_action_at: string | null;
  legal_hold: boolean;
  report_count: number;
  opened_at: string;
  updated_at: string;
};

type CaseEvent = {
  event_id: string;
  kind: string;
  actor_id: string | null;
  actor_role: string | null;
  detail: Record<string, unknown> | null;
  note: string | null;
  created_at: string;
};

type ReportRecord = {
  report_id: string;
  reason: string;
  note: string | null;
  reporter_id: string;
  is_resolved: boolean;
  created_at: string;
};

type AppealRecord = {
  appeal_id: string;
  appellant_id: string;
  statement: string;
  status: string;
  reviewer_id: string | null;
  review_note: string | null;
  created_at: string;
  reviewed_at: string | null;
};

const severityTone: Record<string, Tone> = {
  critical: "crisis",
  high: "danger",
  elevated: "warn",
  normal: "info",
  low: "neutral",
};

async function claimCase(formData: FormData) {
  "use server";
  const caseId = uuid(formData, "case_id");
  const ssr = await createSsrClient();
  const {
    data: { user },
  } = await ssr.auth.getUser();
  if (!user) throw new Error("Not signed in.");

  await rpc("admin_assign_case", {
    p_case: caseId,
    p_assignee: user.id,
    p_reason: "claimed from case detail",
  });
  revalidatePath(`/moderation/cases/${caseId}`);
  revalidatePath("/moderation");
}

async function updateStatus(formData: FormData) {
  "use server";
  const caseId = uuid(formData, "case_id");
  await rpc("admin_set_case_status", {
    p_case: caseId,
    p_status: enumOf(formData, "status", OPEN_STATUSES),
    p_note: reqStr(formData, "note", 500),
  });
  revalidatePath(`/moderation/cases/${caseId}`);
  revalidatePath("/moderation");
}

async function updateLegalHold(formData: FormData) {
  "use server";
  const caseId = uuid(formData, "case_id");
  const hold = enumOf(formData, "hold", ["true", "false"] as const);
  await rpc("admin_set_case_legal_hold", {
    p_case: caseId,
    p_hold: hold === "true",
    p_reason: reqStr(formData, "reason", 500),
  });
  revalidatePath(`/moderation/cases/${caseId}`);
  revalidatePath("/privacy");
}

function evidenceText(evidence: Record<string, unknown> | null): string | null {
  if (!evidence) return null;
  for (const key of ["content", "name", "title", "pseudonym"]) {
    if (typeof evidence[key] === "string") return evidence[key] as string;
  }
  return null;
}

function detailSummary(detail: Record<string, unknown> | null): string | null {
  if (!detail) return null;
  const allowed = ["status", "decision", "policy_code", "legal_hold", "severity"];
  const parts = allowed.flatMap((key) => {
    const value = detail[key];
    return typeof value === "string" || typeof value === "boolean"
      ? [`${key.replaceAll("_", " ")}: ${String(value)}`]
      : [];
  });
  return parts.length > 0 ? parts.join(" · ") : null;
}

export default async function CaseDetailPage({
  params,
}: {
  params: Promise<{ caseId: string }>;
}) {
  const { caseId } = await params;
  if (!UUID_RE.test(caseId)) notFound();

  const db = await createAdminClient();
  const caseResult = await db
    .from("moderation_cases")
    .select(
      "case_id, target_type, target_id, subject_id, status, severity, policy_code, assignee_id, assigned_at, decision, decided_by, decided_at, decision_note, evidence, evidence_hash, evidence_captured_at, sla_due_at, sla_breached_at, first_action_at, legal_hold, report_count, opened_at, updated_at",
    )
    .eq("case_id", caseId)
    .maybeSingle();

  if (caseResult.error) {
    throw new Error(`Could not load moderation case: ${caseResult.error.message}`);
  }
  if (!caseResult.data) notFound();
  const record = caseResult.data as CaseRecord;

  const [eventsResult, reportsResult, appealsResult] = await Promise.all([
    db
      .from("moderation_case_events")
      .select("event_id, kind, actor_id, actor_role, detail, note, created_at")
      .eq("case_id", caseId)
      .order("created_at", { ascending: true })
      .limit(200),
    db
      .from("reports")
      .select("report_id, reason, note, reporter_id, is_resolved, created_at")
      .eq("case_id", caseId)
      .order("created_at", { ascending: true })
      .limit(200),
    db
      .from("moderation_appeals")
      .select(
        "appeal_id, appellant_id, statement, status, reviewer_id, review_note, created_at, reviewed_at",
      )
      .eq("case_id", caseId)
      .order("created_at", { ascending: false })
      .limit(20),
  ]);

  const personIds = [
    record.subject_id,
    record.assignee_id,
    record.decided_by,
    ...(eventsResult.data ?? []).map((event) => event.actor_id as string | null),
  ].filter((id): id is string => !!id);
  const peopleResult =
    personIds.length > 0
      ? await db
          .from("users")
          .select("user_id, display_name, anonymous_pseudonym")
          .in("user_id", [...new Set(personIds)])
      : { data: [], error: null };
  const people = new Map(
    (peopleResult.data ?? []).map((person) => [
      person.user_id,
      person.display_name || `@${person.anonymous_pseudonym}`,
    ]),
  );

  const events = (eventsResult.data ?? []) as CaseEvent[];
  const reports = (reportsResult.data ?? []) as ReportRecord[];
  const appeals = (appealsResult.data ?? []) as AppealRecord[];
  const text = evidenceText(record.evidence);
  const relatedError =
    eventsResult.error?.message ??
    reportsResult.error?.message ??
    appealsResult.error?.message ??
    peopleResult.error?.message ??
    null;

  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <div>
        <Link href="/moderation?tab=cases" className="btn-ghost mb-3">
          <ChevronLeft size={14} /> Case queue
        </Link>
        <PageHeader
          eyebrow="Moderation case"
          title={`${record.target_type.replaceAll("_", " ")} review`}
          subtitle={`Case ${record.case_id}`}
          actions={
            <div className="flex flex-wrap gap-2">
              <Badge tone={severityTone[record.severity] ?? "neutral"}>
                {record.severity}
              </Badge>
              <Badge tone={record.status === "resolved" ? "ok" : "warn"}>
                {record.status.replaceAll("_", " ")}
              </Badge>
              {record.legal_hold && <Badge tone="danger">legal hold</Badge>}
            </div>
          }
        />
      </div>

      {relatedError && (
        <DataWarning title="Some related case data could not be loaded.">
          The case record is intact, but a timeline, report, appeal, or staff
          identity query failed: {relatedError}
        </DataWarning>
      )}

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <div className="flex flex-col gap-6 lg:col-span-2">
          <Card
            title="Preserved evidence"
            hint="Captured when the case opened; private-message bodies stay sealed here"
          >
            {record.evidence?.missing ? (
              <p className="text-sm italic text-ink-muted">
                The target no longer existed when the evidence snapshot ran.
              </p>
            ) : text ? (
              <p className="whitespace-pre-wrap text-sm leading-relaxed text-burgundy">
                {text}
              </p>
            ) : record.target_type === "dm_message" ? (
              <div className="flex items-center gap-2 text-sm text-ink-muted">
                <Lock size={14} /> Private message body withheld. Use the
                separately logged evidence-reveal flow from the case queue only
                when it is necessary to decide the report.
              </div>
            ) : (
              <p className="text-sm italic text-ink-muted">
                No human-readable evidence text is present in the snapshot.
              </p>
            )}
            <div className="mt-4 border-t border-line pt-3">
              <p className="font-mono text-[11px] text-ink-muted">
                SHA-256 {record.evidence_hash}
              </p>
              <p className="mt-1 text-[11px] text-ink-muted">
                captured {new Date(record.evidence_captured_at).toLocaleString()}
              </p>
            </div>
          </Card>

          <Card title="Case timeline" hint={`${events.length} recorded events`} padded={false}>
            {events.length === 0 ? (
              <p className="px-5 py-10 text-sm italic text-ink-muted">
                No case events were returned.
              </p>
            ) : (
              <ol className="divide-y divide-line">
                {events.map((event) => (
                  <li key={event.event_id} className="flex gap-3 px-5 py-4">
                    <div className="mt-1 h-2.5 w-2.5 shrink-0 rounded-full bg-berry" />
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <p className="text-sm font-bold text-burgundy">
                          {event.kind.replaceAll("_", " ")}
                        </p>
                        {event.actor_role && <Badge>{event.actor_role}</Badge>}
                        <time className="ml-auto text-[11px] text-ink-muted">
                          {new Date(event.created_at).toLocaleString()}
                        </time>
                      </div>
                      <p className="text-xs text-ink-muted">
                        {event.actor_id
                          ? people.get(event.actor_id) ?? "Former staff member"
                          : "System"}
                      </p>
                      {event.note && (
                        <p className="mt-1 whitespace-pre-wrap text-sm text-burgundy/90">
                          {event.note}
                        </p>
                      )}
                      {detailSummary(event.detail) && (
                        <p className="mt-1 text-[11px] text-ink-muted">
                          {detailSummary(event.detail)}
                        </p>
                      )}
                    </div>
                  </li>
                ))}
              </ol>
            )}
          </Card>

          <Card title="Source reports" hint={`${reports.length} linked`} padded={false}>
            {reports.length === 0 ? (
              <p className="px-5 py-10 text-sm italic text-ink-muted">
                No source reports were returned.
              </p>
            ) : (
              <ul className="divide-y divide-line">
                {reports.map((report) => (
                  <li key={report.report_id} className="px-5 py-3">
                    <div className="flex flex-wrap items-center gap-2">
                      <Badge tone={report.is_resolved ? "ok" : "warn"}>
                        {report.is_resolved ? "resolved" : "pending"}
                      </Badge>
                      <p className="text-sm font-semibold text-burgundy">
                        {report.reason.replaceAll("_", " ")}
                      </p>
                      <time className="ml-auto text-[11px] text-ink-muted">
                        {new Date(report.created_at).toLocaleString()}
                      </time>
                    </div>
                    {report.note && (
                      <p className="mt-1 whitespace-pre-wrap text-xs text-ink-muted">
                        {report.note}
                      </p>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </Card>

          {appeals.length > 0 && (
            <Card title="Appeals" hint={`${appeals.length} linked`} padded={false}>
              <ul className="divide-y divide-line">
                {appeals.map((appeal) => (
                  <li key={appeal.appeal_id} className="px-5 py-4">
                    <div className="flex items-center gap-2">
                      <Badge tone={appeal.status === "overturned" ? "ok" : "neutral"}>
                        {appeal.status}
                      </Badge>
                      <time className="ml-auto text-[11px] text-ink-muted">
                        {new Date(appeal.created_at).toLocaleString()}
                      </time>
                    </div>
                    <p className="mt-2 whitespace-pre-wrap text-sm text-burgundy">
                      {appeal.statement}
                    </p>
                    {appeal.review_note && (
                      <p className="mt-2 text-xs text-ink-muted">
                        Review: {appeal.review_note}
                      </p>
                    )}
                  </li>
                ))}
              </ul>
            </Card>
          )}
        </div>

        <div className="flex flex-col gap-6">
          <Card title="Case facts">
            <Row label="Target type" value={record.target_type} />
            <Row label="Target ID" value={record.target_type === "post"
              ? <Link href={`/content/${record.target_id}`} className="text-burgundy hover:underline"><code className="text-[10px]">{record.target_id}</code></Link>
              : <code className="text-[10px]">{record.target_id}</code>} />
            <Row
              label="Subject"
              value={
                record.subject_id ? (
                  <Link className="text-berry hover:underline" href={`/users/${record.subject_id}`}>
                    {people.get(record.subject_id) ?? "Open member"}
                  </Link>
                ) : (
                  "—"
                )
              }
            />
            <Row
              label="Assignee"
              value={record.assignee_id ? people.get(record.assignee_id) ?? "Former staff" : "Unassigned"}
            />
            <Row label="Reports" value={record.report_count} />
            <Row label="Policy" value={record.policy_code ?? "—"} />
            <Row label="Opened" value={new Date(record.opened_at).toLocaleString()} />
            <Row
              label="SLA due"
              value={record.sla_due_at ? new Date(record.sla_due_at).toLocaleString() : "—"}
            />
          </Card>

          {record.status !== "resolved" && (
            <Card title="Workflow controls" hint="All changes are audited by the database RPC">
              <div className="flex flex-col gap-4">
                {!record.assignee_id && (
                  <form action={claimCase}>
                    <input type="hidden" name="case_id" value={record.case_id} />
                    <button type="submit" className="btn-secondary w-full">
                      Claim this case
                    </button>
                  </form>
                )}

                <form action={updateStatus} className="flex flex-col gap-2">
                  <input type="hidden" name="case_id" value={record.case_id} />
                  <label className="h-eyebrow">Move workflow</label>
                  <select name="status" className="select" defaultValue="in_review">
                    {OPEN_STATUSES.map((status) => (
                      <option value={status} key={status}>
                        {status.replaceAll("_", " ")}
                      </option>
                    ))}
                  </select>
                  <input
                    name="note"
                    required
                    maxLength={500}
                    className="input"
                    placeholder="Reason for this workflow change"
                  />
                  <button type="submit" className="btn-secondary">
                    Update status
                  </button>
                </form>

                <form action={updateLegalHold} className="flex flex-col gap-2 border-t border-line pt-4">
                  <input type="hidden" name="case_id" value={record.case_id} />
                  <input type="hidden" name="hold" value={String(!record.legal_hold)} />
                  <label className="h-eyebrow">Evidence retention</label>
                  <input
                    name="reason"
                    required
                    maxLength={500}
                    className="input"
                    placeholder="Legal or safety basis"
                  />
                  <button type="submit" className="btn-secondary">
                    {record.legal_hold ? "Release legal hold" : "Place legal hold"}
                  </button>
                </form>
              </div>
            </Card>
          )}

          {record.decision && (
            <Card title="Decision">
              <div className="flex items-center gap-2">
                <ShieldAlert size={15} className="text-berry" />
                <p className="text-sm font-bold text-burgundy">
                  {record.decision.replaceAll("_", " ")}
                </p>
              </div>
              {record.decision_note && (
                <p className="mt-2 whitespace-pre-wrap text-sm text-ink-muted">
                  {record.decision_note}
                </p>
              )}
              <p className="mt-2 flex items-center gap-1 text-[11px] text-ink-muted">
                <Clock size={11} />
                {record.decided_at
                  ? new Date(record.decided_at).toLocaleString()
                  : "Decision time unavailable"}
              </p>
            </Card>
          )}

          <CapabilityNotice title="Final decisions remain in the existing queue for now">
            This dossier deliberately does not add a second decision button.
            The current decision RPC still needs a row lock and terminal-state
            guard before it is safe against concurrent or replayed decisions.
            Review here, then use the existing queue until that backend phase is
            complete.
          </CapabilityNotice>
        </div>
      </div>
    </div>
  );
}
