import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type Row = {
  report_id: string;
  reason: string;
  note: string | null;
  is_resolved: boolean;
  created_at: string;
  post_id: string | null;
  target_comment_id: string | null;
  target_room_id: string | null;
  posts: { content: string; tribe_id: string | null; deleted_at: string | null } | null;
};

async function resolveAction(formData: FormData) {
  "use server";
  const id = formData.get("id");
  if (typeof id !== "string") return;
  const db = createAdminClient();
  await db
    .from("reports")
    .update({ is_resolved: true, resolved_at: new Date().toISOString() })
    .eq("report_id", id);
  revalidatePath("/moderation");
}

async function softDeletePostAction(formData: FormData) {
  "use server";
  const id = formData.get("post_id");
  const reportId = formData.get("report_id");
  if (typeof id !== "string") return;
  const db = createAdminClient();
  await db
    .from("posts")
    .update({ deleted_at: new Date().toISOString() })
    .eq("post_id", id);
  if (typeof reportId === "string") {
    await db
      .from("reports")
      .update({ is_resolved: true, resolved_at: new Date().toISOString() })
      .eq("report_id", reportId);
  }
  revalidatePath("/moderation");
}

const REASON_LABELS: Record<string, string> = {
  self_harm:      "Self-harm concern",
  hate:           "Hate speech",
  harassment:     "Harassment",
  sexual_content: "Sexual content",
  violence:       "Violence",
  privacy:        "Privacy / doxxing",
  spam:           "Spam",
  other:          "Other",
};

export default async function ModerationPage() {
  const db = createAdminClient();
  const { data, error } = await db
    .from("reports")
    .select(
      "report_id, reason, note, is_resolved, created_at, post_id, target_comment_id, target_room_id, posts(content, tribe_id, deleted_at)"
    )
    .order("is_resolved", { ascending: true })
    .order("created_at", { ascending: false })
    .limit(200);

  const rows = (data ?? []) as Row[];
  const pending = rows.filter((r) => !r.is_resolved);
  const resolved = rows.filter((r) => r.is_resolved);

  return (
    <div className="flex flex-col gap-6 max-w-5xl">
      <div>
        <h1 className="text-2xl font-extrabold text-burgundy">Moderation</h1>
        <p className="text-sm text-burgundy/65 mt-1">
          Reports filed by members. Pending items appear first.
        </p>
      </div>

      {error && (
        <div className="card p-4 border-danger/30 text-danger">
          Could not load reports: {error.message}
        </div>
      )}

      <ReportSection
        title="Pending"
        count={pending.length}
        rows={pending}
        emptyText="Nothing pending. Quiet day."
      />

      {resolved.length > 0 && (
        <ReportSection
          title="Resolved"
          count={resolved.length}
          rows={resolved}
          emptyText=""
        />
      )}
    </div>
  );
}

function ReportSection({
  title,
  count,
  rows,
  emptyText,
}: {
  title: string;
  count: number;
  rows: Row[];
  emptyText: string;
}) {
  return (
    <section>
      <div className="flex items-center gap-2 mb-3">
        <h2 className="text-base font-extrabold text-burgundy">{title}</h2>
        <span
          className={`pill ${
            count > 0 && title === "Pending"
              ? "bg-berry/15 text-berry"
              : "bg-mauve/25 text-burgundy/70"
          }`}
        >
          {count}
        </span>
      </div>
      {rows.length === 0 ? (
        <p className="text-sm text-burgundy/55 italic">{emptyText}</p>
      ) : (
        <div className="flex flex-col gap-3">
          {rows.map((r) => (
            <article key={r.report_id} className="card p-4">
              <div className="flex items-center gap-3 mb-2">
                <span className="pill bg-berry/10 text-berry">
                  {REASON_LABELS[r.reason] ?? r.reason}
                </span>
                <span className="text-xs text-burgundy/55">
                  {new Date(r.created_at).toLocaleString()}
                </span>
                <span className="text-xs text-burgundy/40">
                  {r.target_room_id
                    ? "chat"
                    : r.target_comment_id
                      ? "comment"
                      : "post"}
                </span>
                {r.is_resolved && (
                  <span className="pill bg-ok/15 text-ok ml-auto">
                    Resolved
                  </span>
                )}
              </div>
              {r.posts?.deleted_at ? (
                <p className="text-sm italic text-burgundy/55">
                  Post already deleted.
                </p>
              ) : r.posts?.content ? (
                <p className="text-sm text-burgundy/90 whitespace-pre-wrap">
                  {r.posts.content.length > 320
                    ? r.posts.content.slice(0, 320) + "…"
                    : r.posts.content}
                </p>
              ) : (
                <p className="text-sm italic text-burgundy/55">
                  No preview available (chat or deleted content).
                </p>
              )}
              {r.note && (
                <p className="text-xs text-burgundy/65 italic mt-2">
                  Reporter note: {r.note}
                </p>
              )}
              {!r.is_resolved && (
                <div className="flex gap-2 mt-4">
                  <form action={resolveAction}>
                    <input type="hidden" name="id" value={r.report_id} />
                    <button className="btn-secondary" type="submit">
                      Mark resolved
                    </button>
                  </form>
                  {r.post_id && r.posts && !r.posts.deleted_at && (
                    <form action={softDeletePostAction}>
                      <input type="hidden" name="post_id" value={r.post_id} />
                      <input
                        type="hidden"
                        name="report_id"
                        value={r.report_id}
                      />
                      <button className="btn-primary" type="submit">
                        Soft-delete post + resolve
                      </button>
                    </form>
                  )}
                </div>
              )}
            </article>
          ))}
        </div>
      )}
    </section>
  );
}
