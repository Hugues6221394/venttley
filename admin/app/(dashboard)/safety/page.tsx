import { revalidatePath } from "next/cache";
import Link from "next/link";
import { createAdminClient, createSsrClient } from "@/lib/supabase/server";
import { audit, rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { StatCard } from "@/components/ui/stat-card";
import { EmptyState } from "@/components/ui/empty-state";
import { HeartPulse, LifeBuoy, ShieldAlert, CheckCircle2, Clock } from "lucide-react";

export const dynamic = "force-dynamic";

// Rows come from the SECURITY DEFINER admin_safety_queue() RPC (migration 0082).
type SafetyRow = {
  item_type:
    | "crisis_post"
    | "crisis_whisper"
    | "crisis_tribe_message"
    | "crisis_dm"
    | "self_harm_report";
  severity: "high" | "elevated";
  severity_rank: number;
  ref_id: string;
  report_id: string | null;
  reason: string | null;
  note: string | null;
  author_id: string | null;
  author_pseudonym: string | null;
  preview: string | null;
  is_open: boolean;
  created_at: string;
};

const TYPE_LABEL: Record<SafetyRow["item_type"], string> = {
  crisis_post: "Crisis post",
  crisis_whisper: "Crisis whisper",
  crisis_tribe_message: "Crisis chat (tribe)",
  crisis_dm: "Crisis chat (DM)",
  self_harm_report: "Self-harm report",
};

// Maps a crisis content item to the table/kind its "Mark reviewed" action clears.
const CRISIS_KIND: Partial<Record<SafetyRow["item_type"], string>> = {
  crisis_post: "post",
  crisis_whisper: "whisper",
  crisis_tribe_message: "tribe_message",
  crisis_dm: "chat_message",
};

// SLA target for a first human touch, in minutes, by severity.
const SLA_MINUTES: Record<SafetyRow["severity"], number> = {
  high: 15,
  elevated: 60,
};

// ─────────────────────────── server actions ───────────────────────────

async function markReportHandledAction(formData: FormData) {
  "use server";
  const reportId = String(formData.get("report_id") ?? "");
  const note = String(formData.get("note") ?? "");
  if (!reportId) return;
  await rpc("admin_resolve_report", {
    p_report_id: reportId,
    p_action: "safety_handled",
    p_note: note || "Safety follow-up completed",
  });
  revalidatePath("/safety");
}

const CRISIS_TABLE: Record<string, { table: string; idCol: string }> = {
  post: { table: "posts", idCol: "post_id" },
  whisper: { table: "whispers", idCol: "whisper_id" },
  tribe_message: { table: "tribe_messages", idCol: "message_id" },
  chat_message: { table: "chat_messages", idCol: "message_id" },
};

async function clearCrisisAction(formData: FormData) {
  "use server";
  const kind = String(formData.get("kind") ?? "");
  const id = String(formData.get("ref_id") ?? "");
  const note = String(formData.get("note") ?? "");
  const map = CRISIS_TABLE[kind];
  if (!id || !map) return;

  const db = await createAdminClient();
  const { table, idCol } = map;
  const { data: before } = await db
    .from(table)
    .select("crisis_level")
    .eq(idCol, id)
    .maybeSingle();
  await db.from(table).update({ crisis_level: null }).eq(idCol, id);
  await audit(`${kind}.clear_crisis`, {
    targetType: kind,
    targetId: id,
    before: before ?? undefined,
    after: { crisis_level: null },
    reason: note || "Safety review complete",
  });
  revalidatePath("/safety");
}

// ─────────────────────────────── page ───────────────────────────────

export default async function SafetyPage({
  searchParams,
}: {
  searchParams: Promise<{ show?: string }>;
}) {
  const params = await searchParams;
  const includeResolved = params.show === "resolved";

  // Read via the SSR (logged-in admin) client so is_staff(auth.uid()) passes —
  // the service-role client has no auth.uid() and would be rejected.
  const rows = await rpc<SafetyRow[]>("admin_safety_queue", {
    p_include_resolved: includeResolved,
    p_limit: 200,
  });
  const items = rows ?? [];

  const open = items.filter((r) => r.is_open);
  const high = open.filter((r) => r.severity === "high").length;
  const elevated = open.filter((r) => r.severity === "elevated").length;
  const reports = open.filter((r) => r.item_type === "self_harm_report").length;

  return (
    <div className="flex flex-col gap-6 max-w-[1200px]">
      <PageHeader
        eyebrow="Protect"
        title="Safety & Crisis"
        subtitle="Members who may be at risk, prioritised by severity. Reach out with care — every action is audit-logged. This is not a substitute for emergency services."
        actions={
          <Link
            href={includeResolved ? "/safety" : "/safety?show=resolved"}
            className="btn-secondary"
          >
            {includeResolved ? "Show open only" : "Show resolved"}
          </Link>
        }
      />

      {/* Escalation playbook — always visible so on-call has it in front of them. */}
      <Card className="border-l-4 border-l-danger">
        <div className="flex items-start gap-3">
          <LifeBuoy size={20} className="text-danger mt-0.5 shrink-0" />
          <div className="text-sm leading-relaxed">
            <p className="font-extrabold text-burgundy">
              Imminent-danger escalation
            </p>
            <ol className="list-decimal ml-4 mt-1 text-ink-muted space-y-0.5">
              <li>
                In-app crisis resources are shown to the member automatically on
                detection. Confirm they&rsquo;ve been surfaced.
              </li>
              <li>
                Suicide/self-harm cases are a <b>health matter, not a police
                matter</b>. The approved escalation body is{" "}
                <b>Isange One Stop Centre (call 3029)</b> and the{" "}
                <b>Ministry of Health</b> mental-health services — never RIB.
              </li>
              <li>
                For a credible, imminent threat to life, contact emergency
                medical services / Isange (3029). Share only what is necessary,
                through the proper channel — never track the member yourself.
              </li>
              <li>
                Record the outcome with &ldquo;Mark handled&rdquo; so the queue
                and audit trail stay accurate.
              </li>
            </ol>
          </div>
        </div>
      </Card>

      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <StatCard label="Open now" value={open.length} tone={open.length ? "danger" : "ok"} />
        <StatCard label="High severity" value={high} tone={high ? "crisis" : "neutral"} />
        <StatCard label="Elevated" value={elevated} tone={elevated ? "warn" : "neutral"} />
        <StatCard label="Self-harm reports" value={reports} tone={reports ? "warn" : "neutral"} />
      </div>

      <Card
        title={includeResolved ? "All safety items" : "Open safety queue"}
        hint="Highest severity and oldest first"
        padded={false}
      >
        {items.length === 0 ? (
          <div className="p-8">
            <EmptyState
              title="Nothing needs attention"
              hint="No open crisis signals or self-harm reports right now."
              icon={<CheckCircle2 size={28} className="text-ok" />}
            />
          </div>
        ) : (
          <ul className="divide-y divide-line">
            {items.map((r) => (
              <SafetyItem key={`${r.item_type}-${r.ref_id}`} row={r} />
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

function SafetyItem({ row }: { row: SafetyRow }) {
  const ageMin = Math.max(
    0,
    Math.round((Date.now() - new Date(row.created_at).getTime()) / 60000)
  );
  const slaBreached = row.is_open && ageMin > SLA_MINUTES[row.severity];
  const ageLabel =
    ageMin < 60 ? `${ageMin}m` : `${Math.floor(ageMin / 60)}h ${ageMin % 60}m`;

  return (
    <li className="px-5 py-4 flex items-start gap-4">
      <div className="mt-0.5 shrink-0">
        {row.severity === "high" ? (
          <ShieldAlert size={18} className="text-danger" />
        ) : (
          <HeartPulse size={18} className="text-warn" />
        )}
      </div>

      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <Badge tone={row.severity === "high" ? "crisis" : "warn"}>
            {row.severity}
          </Badge>
          <Badge tone="neutral">{TYPE_LABEL[row.item_type]}</Badge>
          {row.author_pseudonym && (
            <Link
              href={`/users?q=${encodeURIComponent(row.author_pseudonym)}`}
              className="text-xs font-bold text-berry hover:underline"
            >
              @{row.author_pseudonym}
            </Link>
          )}
          <span
            className={`pill ${
              slaBreached ? "bg-danger/15 text-danger" : "bg-line text-ink-muted"
            } inline-flex items-center gap-1`}
          >
            <Clock size={11} />
            {slaBreached ? `SLA breached · ${ageLabel}` : ageLabel}
          </span>
          {!row.is_open && <Badge tone="ok">resolved</Badge>}
        </div>

        {row.preview && (
          <p className="text-sm text-ink mt-1.5 line-clamp-3 break-words">
            {row.preview}
          </p>
        )}
        {row.note && (
          <p className="text-xs text-ink-muted mt-1">Reporter note: {row.note}</p>
        )}
      </div>

      {row.is_open && (
        <div className="shrink-0 flex flex-col gap-2 items-end">
          {row.item_type === "self_harm_report" && row.report_id ? (
            <form action={markReportHandledAction}>
              <input type="hidden" name="report_id" value={row.report_id} />
              <button className="btn-secondary text-xs" type="submit">
                Mark handled
              </button>
            </form>
          ) : (
            <form action={clearCrisisAction}>
              <input
                type="hidden"
                name="kind"
                value={CRISIS_KIND[row.item_type] ?? ""}
              />
              <input type="hidden" name="ref_id" value={row.ref_id} />
              <button className="btn-secondary text-xs" type="submit">
                Mark reviewed
              </button>
            </form>
          )}
          <Link href="/moderation" className="text-[11px] text-ink-muted hover:underline">
            Open moderation →
          </Link>
        </div>
      )}
    </li>
  );
}
