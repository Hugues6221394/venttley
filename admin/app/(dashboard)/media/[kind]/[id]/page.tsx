import Link from "next/link";
import { notFound } from "next/navigation";
import { getOperationalRole } from "@/lib/governance";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card, Row as KV } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { ErrorPanel } from "@/components/ui/empty-state";
import { DataWarning } from "@/components/ui/operations";
import { WorkflowForm } from "@/components/workflows/workflow-form";
import { setMediaStatus, requeueMediaScan } from "@/lib/content-actions";

export const dynamic = "force-dynamic";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type Media = { id: string; text: string | null; imageUrl: string | null; status: string; labels: Record<string, unknown> | null; created_at: string; deleted_at: string | null; author_id: string | null };
type AuditRow = { audit_id: string; actor_pseudonym: string; action: string; reason: string | null; created_at: string };

const STATUS_TONE: Record<string, "danger" | "warn" | "neutral" | "ok"> = { blocked: "danger", sensitive: "warn", pending: "neutral", clean: "ok" };
const ACTIONS = [
  ["clean", "Approve", "Shows the image normally to everyone who can see the post."],
  ["sensitive", "Veil as sensitive", "Members see the image behind a tap-to-reveal cover."],
  ["blocked", "Block", "Hides the image from members. The post text stays visible."],
] as const;

export default async function MediaDetailPage({ params }: { params: Promise<{ kind: string; id: string }> }) {
  if (!["super_admin", "admin", "moderator"].includes(await getOperationalRole() ?? "")) notFound();
  const { kind, id } = await params;
  if ((kind !== "post" && kind !== "whisper") || !UUID.test(id)) notFound();
  const db = await createAdminClient();
  const source = kind === "post"
    ? db.from("posts").select("post_id, content, image_url, media_status, media_labels, created_at, deleted_at, author_id").eq("post_id", id).maybeSingle()
    : db.from("whispers").select("whisper_id, title, background_image_url, media_status, media_labels, created_at, deleted_at, author_id").eq("whisper_id", id).maybeSingle();
  const [row, auditResult] = await Promise.all([
    source,
    db.from("audit_log").select("audit_id, actor_pseudonym, action, reason, created_at").eq("target_id", id).order("created_at", { ascending: false }).limit(30),
  ]);
  if (row.error) return <ErrorPanel title="Media unavailable" detail="The record could not be loaded. Refresh to retry; this does not mean it was deleted." />;
  if (!row.data) notFound();
  const r = row.data as Record<string, unknown>;
  const media: Media = {
    id, text: (kind === "post" ? r.content : r.title) as string | null, imageUrl: (kind === "post" ? r.image_url : r.background_image_url) as string | null,
    status: r.media_status as string, labels: r.media_labels as Record<string, unknown> | null, created_at: r.created_at as string,
    deleted_at: r.deleted_at as string | null, author_id: r.author_id as string | null,
  };
  const audit = (auditResult.data ?? []) as AuditRow[];
  const scores = media.labels as { sexual?: number; suggestive?: number; gore?: number; reason?: string } | null;

  return (
    <div className="flex max-w-[1100px] flex-col gap-6">
      <PageHeader eyebrow="Media safety" title={kind === "post" ? "Vent image" : "Whisper background"} subtitle={`Received ${new Date(media.created_at).toLocaleString()}`}
        actions={<div className="flex gap-2">{kind === "post" && <Link href={`/content/${id}`} className="btn-secondary">Open the Vent</Link>}{media.author_id && <Link href={`/users/${media.author_id}`} className="btn-secondary">Author</Link>}<Link href="/media" className="btn-secondary">Media queue</Link></div>} />
      {media.deleted_at && <DataWarning caveat title="This content is deleted">Media review never undeletes. You can still block or veil the image; approving it is refused until the content is restored.</DataWarning>}
      <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <Card title="Image" padded>
          {media.status === "blocked" ? <p className="text-sm text-ink-muted">Blocked images are never shown in the console. Inspect the file in Storage if a second look is needed, then re-scan or approve here.</p>
            : media.imageUrl ? <details className="workflow-technical"><summary>Show image</summary>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={media.imageUrl} alt="Reviewed media" className="mt-3 w-full rounded-lg" />
            </details>
            : <p className="text-sm text-ink-muted">No image is attached any more.</p>}
        </Card>
        <Card title="Verdict" padded>
          <div className="flex flex-wrap gap-2"><Badge tone={STATUS_TONE[media.status] ?? "neutral"}>{media.status}</Badge>{media.deleted_at && <Badge tone="neutral">content deleted</Badge>}</div>
          {scores?.sexual !== undefined && <KV label="Sexual" value={`${Math.round((scores.sexual ?? 0) * 100)}%`} />}
          {scores?.suggestive !== undefined && <KV label="Suggestive" value={`${Math.round((scores.suggestive ?? 0) * 100)}%`} />}
          {scores?.gore !== undefined && <KV label="Gore" value={`${Math.round((scores.gore ?? 0) * 100)}%`} />}
          {scores?.reason && <KV label="Scanner note" value={scores.reason} />}
          {media.text && <div className="py-2"><p className="h-eyebrow">{kind === "post" ? "Vent text" : "Whisper title"}</p><p className="mt-1 line-clamp-6 text-sm text-ink">{media.text}</p></div>}
        </Card>
        <Card title="Decide" hint="Each needs a reason and is audited" padded>
          <div className="flex flex-col gap-4">
            {ACTIONS.filter(([status]) => status !== media.status).map(([status, label, confirmation]) =>
              <WorkflowForm key={status} action={setMediaStatus} blockUncertainRetry label={label} confirmation={confirmation}>
                <input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} /><input type="hidden" name="status" value={status} />
                <label className="contact-field"><span>Reason</span><input name="reason" className="input" required minLength={3} maxLength={500} /></label>
              </WorkflowForm>)}
            <WorkflowForm action={requeueMediaScan} blockUncertainRetry label="Scan again" confirmation="Sends the image back to the scanner. It is hidden as pending until the new verdict arrives.">
              <input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} />
              <label className="contact-field"><span>Reason</span><input name="reason" className="input" required minLength={3} maxLength={500} placeholder="e.g. scanner outage" /></label>
            </WorkflowForm>
          </div>
        </Card>
      </div>
      <Card title="History" hint="Latest 30 audited actions on this content" padded={false}>
        {auditResult.error ? <p className="px-5 py-8 text-center text-sm italic text-ink-muted">History could not be loaded.</p>
          : audit.length === 0 ? <p className="px-5 py-8 text-center text-sm italic text-ink-muted">No staff action recorded yet.</p>
          : <ul className="divide-y divide-line">{audit.map((a) => <li key={a.audit_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Badge>{a.action}</Badge><span className="text-xs text-ink-muted">@{a.actor_pseudonym}</span><time className="ml-auto text-[11px] text-ink-muted">{new Date(a.created_at).toLocaleString()}</time></div>{a.reason && <p className="mt-1 text-xs text-ink-muted">{a.reason}</p>}</li>)}</ul>}
      </Card>
    </div>
  );
}
