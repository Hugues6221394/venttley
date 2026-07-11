import { revalidatePath } from "next/cache";
import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { audit, rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { Tabs } from "@/components/ui/tabs";
import { EmptyState } from "@/components/ui/empty-state";
import {
  AlertCircle,
  Ban,
  CheckCircle2,
  EyeOff,
  Heart,
  ShieldAlert,
  Trash2,
  Clock,
} from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type ReportRow = {
  report_id: string;
  reason: string;
  note: string | null;
  is_resolved: boolean;
  created_at: string;
  resolved_at: string | null;
  post_id: string | null;
  target_comment_id: string | null;
  target_room_id: string | null;
  target_tribe_message_id: string | null;
  target_chat_message_id: string | null;
  posts: {
    content: string;
    tribe_id: string | null;
    deleted_at: string | null;
    author_id: string;
    crisis_level: string | null;
  } | null;
};

type CrisisRow = {
  post_id: string;
  content: string;
  crisis_level: "elevated" | "high";
  author_id: string;
  author_pseudonym: string;
  created_at: string;
};

const REASON_LABEL: Record<string, string> = {
  self_harm: "Self-harm",
  hate: "Hate speech",
  harassment: "Harassment",
  sexual_content: "Sexual content",
  violence: "Violence",
  privacy: "Privacy / doxxing",
  spam: "Spam",
  other: "Other",
};

const REASON_TONE: Record<string, "ok" | "warn" | "danger" | "info" | "neutral"> = {
  self_harm: "crisis" as never,
  hate: "danger",
  harassment: "danger",
  sexual_content: "warn",
  violence: "danger",
  privacy: "warn",
  spam: "info",
  other: "neutral",
};

// ──────────────────────────── Server actions ────────────────────────────

async function resolveAction(formData: FormData) {
  "use server";
  const id = String(formData.get("report_id") ?? "");
  const reason = String(formData.get("reason") ?? "");
  if (!id) return;
  await rpc("admin_resolve_report", {
    p_report_id: id,
    p_action: "dismissed",
    p_note: reason || null,
  });
  revalidatePath("/moderation");
}

async function softDeletePostAction(formData: FormData) {
  "use server";
  const postId = String(formData.get("post_id") ?? "");
  const reportId = String(formData.get("report_id") ?? "");
  const reason = String(formData.get("reason") ?? "");
  if (!postId) return;
  await rpc("admin_set_post_deleted", {
    p_post_id: postId,
    p_deleted: true,
    p_reason: reason || null,
  });
  if (reportId) {
    await rpc("admin_resolve_report", {
      p_report_id: reportId,
      p_action: "content_deleted",
      p_note: reason || null,
    });
  }
  revalidatePath("/moderation");
}

async function suspendAuthorAction(formData: FormData) {
  "use server";
  const userId = String(formData.get("user_id") ?? "");
  const reportId = String(formData.get("report_id") ?? "");
  const reason = String(formData.get("reason") ?? "");
  if (!userId) return;
  await rpc("admin_set_user_status", {
    p_target: userId,
    p_status: "suspended",
    p_reason: reason || null,
  });
  if (reportId) {
    await rpc("admin_resolve_report", {
      p_report_id: reportId,
      p_action: "user_suspended",
      p_note: reason || null,
    });
  }
  revalidatePath("/moderation");
}

async function shadowBanAction(formData: FormData) {
  "use server";
  const userId = String(formData.get("user_id") ?? "");
  const reportId = String(formData.get("report_id") ?? "");
  const reason = String(formData.get("reason") ?? "");
  if (!userId) return;
  await rpc("admin_set_user_status", {
    p_target: userId,
    p_status: "shadow_banned",
    p_reason: reason || null,
  });
  if (reportId) {
    await rpc("admin_resolve_report", {
      p_report_id: reportId,
      p_action: "user_shadow_banned",
      p_note: reason || null,
    });
  }
  revalidatePath("/moderation");
}

async function suspendLadderAction(formData: FormData) {
  "use server";
  const userId = String(formData.get("user_id") ?? "");
  const reportId = String(formData.get("report_id") ?? "");
  const reason = String(formData.get("reason") ?? "");
  if (!userId) return;
  // Escalating temp-ban: the RPC picks the tier from the user's history.
  await rpc("admin_suspend_user_ladder", {
    p_target: userId,
    p_reason: reason || null,
  });
  if (reportId) {
    await rpc("admin_resolve_report", {
      p_report_id: reportId,
      p_action: "user_suspended",
      p_note: reason || null,
    });
  }
  revalidatePath("/moderation");
}

async function bulkResolveAction(formData: FormData) {
  "use server";
  const ids = formData.getAll("report_ids").map(String).filter(Boolean);
  const reason = String(formData.get("reason") ?? "");
  if (ids.length === 0) return;
  await rpc("admin_bulk_resolve_reports", {
    p_report_ids: ids,
    p_action: "dismissed",
    p_note: reason || "Bulk dismissed",
  });
  revalidatePath("/moderation");
}

async function clearCrisisFlagAction(formData: FormData) {
  "use server";
  const postId = String(formData.get("post_id") ?? "");
  const reason = String(formData.get("reason") ?? "");
  if (!postId) return;
  // The classifier wrote crisis_level; admin override here. We do a direct
  // UPDATE via the admin client because set_post_crisis is author-only; in
  // the rebuild we expose admin overrides via admin_log + a direct write.
  const db = await createAdminClient();
  const { data: before } = await db
    .from("posts")
    .select("crisis_level")
    .eq("post_id", postId)
    .maybeSingle();
  await db.from("posts").update({ crisis_level: null }).eq("post_id", postId);
  await audit("post.clear_crisis", {
    targetType: "post",
    targetId: postId,
    before: before ?? undefined,
    after: { crisis_level: null },
    reason: reason || undefined,
  });
  revalidatePath("/moderation");
}

// ──────────────────────────── Page ────────────────────────────

export default async function ModerationPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; reason?: string }>;
}) {
  const params = await searchParams;
  const tab = params.tab ?? "pending";
  const reasonFilter = params.reason ?? "";

  const db = await createAdminClient();

  // Pull what we need for the tab badges (separate counts so the page chrome
  // stays accurate regardless of which tab is selected).
  const [pendingCountRes, resolvedCountRes, crisisCountRes] = await Promise.all([
    db
      .from("reports")
      .select("report_id", { count: "exact", head: true })
      .eq("is_resolved", false),
    db
      .from("reports")
      .select("report_id", { count: "exact", head: true })
      .eq("is_resolved", true),
    db
      .from("posts")
      .select("post_id", { count: "exact", head: true })
      .not("crisis_level", "is", null)
      .is("deleted_at", null),
  ]);

  let reports: ReportRow[] = [];
  let crisis: CrisisRow[] = [];

  if (tab === "crisis") {
    const { data } = await db
      .from("feed_posts")
      .select(
        "post_id, content, crisis_level, author_id, author_pseudonym, created_at"
      )
      .not("crisis_level", "is", null)
      .is("deleted_at", null)
      .order("created_at", { ascending: false })
      .limit(200);
    crisis = (data ?? []) as CrisisRow[];
  } else {
    let q = db
      .from("reports")
      .select(
        "report_id, reason, note, is_resolved, created_at, resolved_at, post_id, target_comment_id, target_room_id, target_tribe_message_id, target_chat_message_id, posts(content, tribe_id, deleted_at, author_id, crisis_level)"
      )
      .order("created_at", { ascending: false })
      .limit(200);
    if (tab === "pending") q = q.eq("is_resolved", false);
    if (tab === "resolved") q = q.eq("is_resolved", true);
    if (reasonFilter) q = q.eq("reason", reasonFilter);
    const { data } = await q;
    reports = (data ?? []) as unknown as ReportRow[];
  }

  const tabs = [
    {
      key: "pending",
      label: "Pending",
      count: pendingCountRes.count ?? 0,
      tone: (pendingCountRes.count ?? 0) > 0 ? ("warn" as const) : ("neutral" as const),
    },
    {
      key: "crisis",
      label: "Crisis-flagged",
      count: crisisCountRes.count ?? 0,
      tone: (crisisCountRes.count ?? 0) > 0 ? ("danger" as const) : ("neutral" as const),
    },
    { key: "resolved", label: "Resolved", count: resolvedCountRes.count ?? 0 },
    { key: "all", label: "All" },
  ];

  return (
    <div className="flex flex-col gap-6 max-w-[1200px]">
      <PageHeader
        eyebrow="Operate"
        title="Moderation"
        subtitle="Triage reports, manage crisis-flagged posts, and act on accounts. Every action is captured in the audit log."
        actions={
          <Link href="/audit?action=user" className="btn-secondary">
            Moderator activity
          </Link>
        }
      />

      <Tabs
        tabs={tabs}
        active={tab}
        basePath="/moderation"
        extraParams={{ reason: reasonFilter }}
      />

      {tab !== "crisis" && (
        <ReasonFilter active={reasonFilter} basePath="/moderation" tab={tab} />
      )}

      {tab === "crisis" ? (
        <CrisisQueue
          rows={crisis}
          onDelete={softDeletePostAction}
          onClearFlag={clearCrisisFlagAction}
          onSuspend={suspendAuthorAction}
        />
      ) : (
        <>
          <BulkBar reports={reports} onBulkResolve={bulkResolveAction} />
          <ReportQueue
            rows={reports}
            showResolved={tab !== "pending"}
            onResolve={resolveAction}
            onDelete={softDeletePostAction}
            onSuspend={suspendAuthorAction}
            onShadow={shadowBanAction}
            onLadder={suspendLadderAction}
          />
        </>
      )}
    </div>
  );
}

// Batch-dismiss every pending report currently shown (respects the active
// reason filter). Not nested with the per-card forms, so no invalid HTML.
function BulkBar({
  reports,
  onBulkResolve,
}: {
  reports: ReportRow[];
  onBulkResolve: (fd: FormData) => Promise<void>;
}) {
  const pending = reports.filter((r) => !r.is_resolved);
  if (pending.length < 2) return null;
  return (
    <form
      action={onBulkResolve}
      className="surface-flat flex flex-wrap items-center gap-3 px-4 py-3"
    >
      {pending.map((r) => (
        <input key={r.report_id} type="hidden" name="report_ids" value={r.report_id} />
      ))}
      <p className="text-sm font-semibold text-burgundy">
        {pending.length} pending report{pending.length === 1 ? "" : "s"} shown
      </p>
      <input
        type="text"
        name="reason"
        placeholder="reason (optional)"
        className="input h-8 w-44 text-xs ml-auto"
      />
      <button type="submit" className="btn-secondary">
        Dismiss all shown
      </button>
    </form>
  );
}

// ──────────────────────────── Sub-components ────────────────────────────

function ReasonFilter({
  active,
  basePath,
  tab,
}: {
  active: string;
  basePath: string;
  tab: string;
}) {
  const reasons = ["", ...Object.keys(REASON_LABEL)];
  return (
    <div className="flex flex-wrap gap-1.5">
      {reasons.map((r) => {
        const sp = new URLSearchParams();
        sp.set("tab", tab);
        if (r) sp.set("reason", r);
        const on = (active || "") === r;
        return (
          <Link
            key={r || "all"}
            href={`${basePath}?${sp.toString()}`}
            className={`pill border ${
              on
                ? "bg-berry text-white border-berry"
                : "bg-white text-burgundy border-line hover:bg-canvas"
            }`}
          >
            {r ? REASON_LABEL[r] : "All reasons"}
          </Link>
        );
      })}
    </div>
  );
}

function ReportQueue({
  rows,
  showResolved,
  onResolve,
  onDelete,
  onSuspend,
  onShadow,
  onLadder,
}: {
  rows: ReportRow[];
  showResolved: boolean;
  onResolve: (fd: FormData) => Promise<void>;
  onDelete: (fd: FormData) => Promise<void>;
  onSuspend: (fd: FormData) => Promise<void>;
  onShadow: (fd: FormData) => Promise<void>;
  onLadder: (fd: FormData) => Promise<void>;
}) {
  if (rows.length === 0) {
    return (
      <Card padded={false}>
        <div className="px-5 py-12">
          <EmptyState
            icon={<CheckCircle2 size={36} />}
            title={
              showResolved
                ? "No matching reports."
                : "Inbox zero — nothing pending."
            }
            hint="Filters are sticky in the URL. Clear them with the reason chips."
          />
        </div>
      </Card>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      {rows.map((r) => {
        const target = r.target_tribe_message_id
          ? "tribe message"
          : r.target_chat_message_id
            ? "dm message"
            : r.target_room_id
              ? "chat"
              : r.target_comment_id
                ? "comment"
                : "post";
        const tone = REASON_TONE[r.reason] ?? "neutral";
        const crisis = r.posts?.crisis_level;
        const deleted = !!r.posts?.deleted_at;

        return (
          <article key={r.report_id} className="surface p-5">
            <header className="flex flex-wrap items-center gap-2 mb-3">
              <Badge
                tone={tone}
                icon={<ShieldAlert size={11} />}
              >
                {REASON_LABEL[r.reason] ?? r.reason}
              </Badge>
              <span className="pill bg-line text-ink-muted uppercase">
                {target}
              </span>
              {crisis && (
                <Badge tone="crisis" icon={<Heart size={11} fill="currentColor" />}>
                  crisis · {crisis}
                </Badge>
              )}
              {deleted && (
                <Badge tone="neutral">
                  <Trash2 size={11} /> deleted
                </Badge>
              )}
              <span className="text-xs text-ink-muted flex items-center gap-1 ml-auto">
                <Clock size={12} />
                {timeAgo(r.created_at)}
              </span>
              {r.is_resolved && (
                <Badge tone="ok" icon={<CheckCircle2 size={11} />}>
                  resolved
                </Badge>
              )}
            </header>

            {deleted ? (
              <p className="text-sm italic text-ink-muted">
                Content already deleted.
              </p>
            ) : r.posts?.content ? (
              <p className="text-sm text-burgundy whitespace-pre-wrap leading-relaxed">
                {truncate(r.posts.content, 480)}
              </p>
            ) : (
              <p className="text-sm italic text-ink-muted">
                No preview available (chat or unknown target).
              </p>
            )}

            {r.note && (
              <p className="text-xs text-ink-muted italic mt-3 border-l-2 border-line pl-3">
                Reporter note: {r.note}
              </p>
            )}

            {!r.is_resolved && (
              <div className="mt-4 flex flex-wrap gap-2 pt-4 border-t border-line">
                <ActionForm
                  action={onResolve}
                  reportId={r.report_id}
                  label="Dismiss"
                  variant="secondary"
                  icon={<CheckCircle2 size={14} />}
                  promptReason
                />
                {r.post_id && !deleted && (
                  <ActionForm
                    action={onDelete}
                    reportId={r.report_id}
                    postId={r.post_id}
                    label="Delete + resolve"
                    variant="danger"
                    icon={<Trash2 size={14} />}
                    promptReason
                  />
                )}
                {r.posts?.author_id && (
                  <>
                    <ActionForm
                      action={onLadder}
                      reportId={r.report_id}
                      userId={r.posts.author_id}
                      label="Ladder suspend"
                      variant="secondary"
                      icon={<Clock size={14} />}
                      promptReason
                    />
                    <ActionForm
                      action={onSuspend}
                      reportId={r.report_id}
                      userId={r.posts.author_id}
                      label="Suspend author"
                      variant="secondary"
                      icon={<Ban size={14} />}
                      promptReason
                    />
                    <ActionForm
                      action={onShadow}
                      reportId={r.report_id}
                      userId={r.posts.author_id}
                      label="Shadow-ban"
                      variant="ghost"
                      icon={<EyeOff size={14} />}
                      promptReason
                    />
                  </>
                )}
              </div>
            )}
          </article>
        );
      })}
    </div>
  );
}

function CrisisQueue({
  rows,
  onDelete,
  onClearFlag,
  onSuspend,
}: {
  rows: CrisisRow[];
  onDelete: (fd: FormData) => Promise<void>;
  onClearFlag: (fd: FormData) => Promise<void>;
  onSuspend: (fd: FormData) => Promise<void>;
}) {
  if (rows.length === 0) {
    return (
      <Card padded={false}>
        <div className="px-5 py-12">
          <EmptyState
            icon={<CheckCircle2 size={36} />}
            title="No crisis-flagged posts in the queue."
            hint="The safety classifier writes these when it detects self-harm or suicidal-ideation signals."
          />
        </div>
      </Card>
    );
  }
  return (
    <div className="flex flex-col gap-3">
      <p className="text-xs text-ink-muted">
        These posts are surfacing the helpline banner on the mobile app right
        now. Delete or clear with care — the goal is reachability of support,
        not censorship.
      </p>
      {rows.map((p) => (
        <article key={p.post_id} className="surface p-5">
          <header className="flex items-center gap-2 mb-3">
            <Badge
              tone={p.crisis_level === "high" ? "crisis" : "danger"}
              icon={<Heart size={11} fill="currentColor" />}
            >
              crisis · {p.crisis_level}
            </Badge>
            <span className="text-xs text-ink-muted">{p.author_pseudonym}</span>
            <span className="text-xs text-ink-muted flex items-center gap-1 ml-auto">
              <Clock size={12} />
              {timeAgo(p.created_at)}
            </span>
          </header>
          <p className="text-sm text-burgundy whitespace-pre-wrap leading-relaxed">
            {truncate(p.content, 480)}
          </p>
          <div className="mt-4 flex flex-wrap gap-2 pt-4 border-t border-line">
            <ActionForm
              action={onClearFlag}
              postId={p.post_id}
              label="Clear crisis flag"
              variant="secondary"
              icon={<CheckCircle2 size={14} />}
              promptReason
            />
            <ActionForm
              action={onDelete}
              postId={p.post_id}
              label="Soft-delete post"
              variant="danger"
              icon={<Trash2 size={14} />}
              promptReason
            />
            <ActionForm
              action={onSuspend}
              userId={p.author_id}
              label="Suspend author"
              variant="ghost"
              icon={<Ban size={14} />}
              promptReason
            />
          </div>
        </article>
      ))}
    </div>
  );
}

function ActionForm({
  action,
  reportId,
  postId,
  userId,
  label,
  icon,
  variant,
  promptReason,
}: {
  action: (fd: FormData) => Promise<void>;
  reportId?: string;
  postId?: string;
  userId?: string;
  label: string;
  icon?: React.ReactNode;
  variant: "primary" | "secondary" | "danger" | "ghost";
  promptReason?: boolean;
}) {
  const cls =
    variant === "primary"
      ? "btn-primary"
      : variant === "danger"
        ? "btn-danger"
        : variant === "ghost"
          ? "btn-ghost"
          : "btn-secondary";
  return (
    <form action={action} className="flex items-center gap-2">
      {reportId && <input type="hidden" name="report_id" value={reportId} />}
      {postId && <input type="hidden" name="post_id" value={postId} />}
      {userId && <input type="hidden" name="user_id" value={userId} />}
      {promptReason && (
        <input
          type="text"
          name="reason"
          placeholder="reason (optional)"
          className="input h-8 w-44 text-xs"
        />
      )}
      <button type="submit" className={cls}>
        {icon}
        {label}
      </button>
    </form>
  );
}

function timeAgo(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

function truncate(s: string, max: number): string {
  if (s.length <= max) return s;
  return s.slice(0, max).trimEnd() + "…";
}
