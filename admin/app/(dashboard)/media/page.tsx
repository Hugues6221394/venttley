import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { StatCard } from "@/components/ui/stat-card";
import { EmptyState } from "@/components/ui/empty-state";
import { ShieldCheck, Check, Ban } from "lucide-react";

export const dynamic = "force-dynamic";

type MediaRow = {
  kind: "post" | "whisper";
  id: string;
  preview: string | null;
  imageUrl: string | null;
  status: "pending" | "sensitive" | "blocked";
  labels: Record<string, unknown> | null;
  created_at: string;
};

const STATUS_TONE: Record<MediaRow["status"], "danger" | "warn" | "neutral"> = {
  blocked: "danger",
  sensitive: "warn",
  pending: "neutral",
};

async function setStatusAction(formData: FormData) {
  "use server";
  const kind = String(formData.get("kind") ?? "");
  const id = String(formData.get("id") ?? "");
  const status = String(formData.get("status") ?? "");
  const reason = String(formData.get("reason") ?? "");
  if (!id || (kind !== "post" && kind !== "whisper")) return;
  await rpc("admin_set_media_status", {
    p_kind: kind,
    p_id: id,
    p_status: status,
    p_reason: reason || null,
  });
  revalidatePath("/media");
}

export default async function MediaPage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string }>;
}) {
  const params = await searchParams;
  const filter = params.status ?? "flagged"; // flagged = blocked+sensitive+pending

  const db = await createAdminClient();
  const statuses =
    filter === "blocked"
      ? ["blocked"]
      : filter === "sensitive"
        ? ["sensitive"]
        : ["blocked", "sensitive", "pending"];

  const [postsRes, whispersRes, countsRes] = await Promise.all([
    db
      .from("posts")
      .select("post_id, content, image_url, media_status, media_labels, created_at")
      .in("media_status", statuses)
      .not("image_url", "is", null)
      .order("created_at", { ascending: false })
      .limit(150),
    db
      .from("whispers")
      .select("whisper_id, title, background_image_url, media_status, media_labels, created_at")
      .in("media_status", statuses)
      .not("background_image_url", "is", null)
      .order("created_at", { ascending: false })
      .limit(150),
    db
      .from("posts")
      .select("media_status")
      .in("media_status", ["blocked", "sensitive"])
      .not("image_url", "is", null),
  ]);

  const rows: MediaRow[] = [
    ...((postsRes.data ?? []) as Array<Record<string, unknown>>).map((p) => ({
      kind: "post" as const,
      id: p.post_id as string,
      preview: (p.content as string) ?? null,
      imageUrl: (p.image_url as string) ?? null,
      status: p.media_status as MediaRow["status"],
      labels: (p.media_labels as Record<string, unknown>) ?? null,
      created_at: p.created_at as string,
    })),
    ...((whispersRes.data ?? []) as Array<Record<string, unknown>>).map((w) => ({
      kind: "whisper" as const,
      id: w.whisper_id as string,
      preview: (w.title as string) ?? "Voice whisper",
      imageUrl: (w.background_image_url as string) ?? null,
      status: w.media_status as MediaRow["status"],
      labels: (w.media_labels as Record<string, unknown>) ?? null,
      created_at: w.created_at as string,
    })),
  ].sort((a, b) => (a.created_at < b.created_at ? 1 : -1));

  const counts = (countsRes.data ?? []) as Array<{ media_status: string }>;
  const blocked = counts.filter((c) => c.media_status === "blocked").length;
  const sensitive = counts.filter((c) => c.media_status === "sensitive").length;

  return (
    <div className="flex flex-col gap-6 max-w-[1200px]">
      <PageHeader
        eyebrow="Operate"
        title="Media safety"
        subtitle="Images the classifier auto-blocked (nudity/gore) or veiled (sensitive). Blocked media is already hidden from users — review here for false positives. Every override is audit-logged."
      />

      <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
        <StatCard label="Auto-blocked" value={blocked} tone={blocked ? "danger" : "ok"} />
        <StatCard label="Veiled (sensitive)" value={sensitive} tone={sensitive ? "warn" : "neutral"} />
        <StatCard label="Shown here" value={rows.length} tone="info" />
      </div>

      <Card padded={false}>
        {rows.length === 0 ? (
          <div className="p-8">
            <EmptyState
              title="Nothing flagged"
              hint="No blocked or sensitive media right now."
              icon={<ShieldCheck size={26} className="text-ok" />}
            />
          </div>
        ) : (
          <ul className="divide-y divide-line">
            {rows.map((r) => (
              <MediaItem key={`${r.kind}-${r.id}`} row={r} />
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

function MediaItem({ row }: { row: MediaRow }) {
  const scores = row.labels as
    | { sexual?: number; suggestive?: number; gore?: number; reason?: string }
    | null;
  return (
    <li className="px-5 py-4 flex items-start gap-4">
      {/* Blocked images are still veiled here — staff can hover/click to inspect
          in Supabase Storage if needed; we don't auto-render explicit content. */}
      <div className="h-16 w-16 shrink-0 rounded-lg bg-line flex items-center justify-center overflow-hidden">
        {row.status === "blocked" ? (
          <Ban size={20} className="text-danger" />
        ) : (
          // Sensitive/pending: show a blurred thumbnail hint.
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={row.imageUrl ?? ""}
            alt=""
            className="h-full w-full object-cover blur-md"
          />
        )}
      </div>

      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <Badge tone={STATUS_TONE[row.status]}>{row.status}</Badge>
          <Badge tone="neutral">{row.kind}</Badge>
          {scores?.sexual !== undefined && (
            <span className="text-[11px] text-ink-muted tabular">
              sexual {Math.round((scores.sexual ?? 0) * 100)}% · gore{" "}
              {Math.round((scores.gore ?? 0) * 100)}%
            </span>
          )}
          {scores?.reason && (
            <span className="text-[11px] text-ink-muted italic">{scores.reason}</span>
          )}
        </div>
        {row.preview && (
          <p className="text-sm text-ink mt-1 line-clamp-2 break-words">{row.preview}</p>
        )}
      </div>

      <div className="shrink-0 flex flex-col gap-2 items-end">
        <form action={setStatusAction} className="flex items-center gap-2">
          <input type="hidden" name="kind" value={row.kind} />
          <input type="hidden" name="id" value={row.id} />
          <input type="hidden" name="status" value="clean" />
          <button className="btn-secondary text-xs" type="submit">
            <Check size={13} /> Approve
          </button>
        </form>
        {row.status !== "blocked" && (
          <form action={setStatusAction}>
            <input type="hidden" name="kind" value={row.kind} />
            <input type="hidden" name="id" value={row.id} />
            <input type="hidden" name="status" value="blocked" />
            <button className="btn-ghost text-xs text-danger" type="submit">
              <Ban size={13} /> Block
            </button>
          </form>
        )}
      </div>
    </li>
  );
}
