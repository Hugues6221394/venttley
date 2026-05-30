import { revalidatePath } from "next/cache";
import { createAdminClient, createSsrClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type Broadcast = {
  broadcast_id: string;
  title: string;
  body: string;
  recipient_count: number;
  created_at: string;
  sent_by: string | null;
  users: { anonymous_pseudonym: string } | null;
};

async function broadcastAction(formData: FormData) {
  "use server";
  const title = formData.get("title");
  const body = formData.get("body");
  if (typeof title !== "string" || typeof body !== "string") return;
  if (title.trim().length < 3 || body.trim().length < 3) return;

  const ssr = await createSsrClient();
  const {
    data: { user },
  } = await ssr.auth.getUser();
  if (!user) return;

  const db = await createAdminClient();

  // Fan out one notification row per active member.
  const { data: recipients } = await db
    .from("users")
    .select("user_id")
    .eq("account_status", "active");
  const ids = (recipients ?? []).map((r) => r.user_id as string);

  if (ids.length > 0) {
    const rows = ids.map((id) => ({
      user_id: id,
      kind: "admin_broadcast",
      payload: { title: title.trim(), body: body.trim() },
      is_read: false,
    }));
    // Insert in chunks of 500 to stay under PostgREST limits.
    for (let i = 0; i < rows.length; i += 500) {
      await db.from("notifications").insert(rows.slice(i, i + 500));
    }
  }

  await db.from("admin_broadcasts").insert({
    sent_by: user.id,
    title: title.trim(),
    body: body.trim(),
    recipient_count: ids.length,
  });

  revalidatePath("/notifications");
}

export default async function AdminNotificationsPage() {
  const db = await createAdminClient();
  const { data: broadcasts, error } = await db
    .from("admin_broadcasts")
    .select(
      "broadcast_id, title, body, recipient_count, created_at, sent_by, users:sent_by(anonymous_pseudonym)"
    )
    .order("created_at", { ascending: false })
    .limit(50);

  const rows = (broadcasts ?? []) as unknown as Broadcast[];

  const { count: activeMembers } = await db
    .from("users")
    .select("user_id", { count: "exact", head: true })
    .eq("account_status", "active");

  return (
    <div className="flex flex-col gap-6 max-w-4xl">
      <div>
        <h1 className="text-2xl font-extrabold text-burgundy">Notifications</h1>
        <p className="text-sm text-burgundy/65 mt-1">
          Compose a platform-wide announcement. Lands in every active member’s
          notification feed.
        </p>
      </div>

      <form
        action={broadcastAction}
        className="card p-5 flex flex-col gap-3"
      >
        <p className="text-[11px] font-bold uppercase tracking-widest text-burgundy/60">
          Will reach {(activeMembers ?? 0).toLocaleString()} active members
        </p>
        <label className="text-xs font-semibold text-burgundy/75">
          Title
          <input
            name="title"
            required
            maxLength={80}
            className="mt-1 w-full rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm focus:border-berry"
            placeholder="A short, calm headline"
          />
        </label>
        <label className="text-xs font-semibold text-burgundy/75">
          Message
          <textarea
            name="body"
            required
            maxLength={500}
            rows={4}
            className="mt-1 w-full rounded-xl border border-mauve/50 bg-white px-3 py-2 text-sm focus:border-berry resize-y"
            placeholder="One paragraph. No marketing copy — keep the soft tone."
          />
        </label>
        <div>
          <button className="btn-primary" type="submit">
            Send announcement
          </button>
        </div>
        <p className="text-[11px] text-burgundy/55">
          Inserts one notifications row per recipient + one row in
          admin_broadcasts for audit. There is no recall — preview carefully.
        </p>
      </form>

      <section>
        <h2 className="text-base font-extrabold text-burgundy mb-3">
          Recent broadcasts
        </h2>

        {error && (
          <div className="card p-4 border-danger/30 text-danger">
            Could not load broadcasts: {error.message}
          </div>
        )}

        {rows.length === 0 && (
          <p className="text-sm text-burgundy/55 italic">
            No announcements yet.
          </p>
        )}

        <div className="flex flex-col gap-3">
          {rows.map((b) => (
            <article key={b.broadcast_id} className="card p-4">
              <div className="flex items-center justify-between">
                <h3 className="text-base font-extrabold text-burgundy">
                  {b.title}
                </h3>
                <span className="text-xs text-burgundy/55">
                  {new Date(b.created_at).toLocaleString()}
                </span>
              </div>
              <p className="mt-1 text-sm text-burgundy/85 whitespace-pre-wrap">
                {b.body}
              </p>
              <p className="mt-3 text-[11px] text-burgundy/55">
                Sent by @{b.users?.anonymous_pseudonym ?? "unknown"} · reached{" "}
                {b.recipient_count.toLocaleString()} member
                {b.recipient_count === 1 ? "" : "s"}
              </p>
            </article>
          ))}
        </div>
      </section>
    </div>
  );
}
