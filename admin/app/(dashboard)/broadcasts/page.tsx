import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";
import { rpc, audit } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Megaphone, AlertTriangle, Heart, Info } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Row = {
  broadcast_id: string;
  title: string;
  body: string;
  urgency: "info" | "warning" | "critical" | "crisis";
  audience: { scope: string; value?: string };
  scheduled_for: string | null;
  sent_at: string | null;
  expires_at: string | null;
  delivered_count: number;
  dismissed_count: number;
  is_active: boolean;
  created_at: string;
};

async function sendBroadcastAction(formData: FormData) {
  "use server";
  const title = String(formData.get("title") ?? "").trim();
  const body = String(formData.get("body") ?? "").trim();
  const urgency = String(formData.get("urgency") ?? "info");
  const scope = String(formData.get("scope") ?? "all");
  const scopeValue = String(formData.get("scope_value") ?? "").trim();
  const scheduledFor = String(formData.get("scheduled_for") ?? "").trim();
  const expiresAt = String(formData.get("expires_at") ?? "").trim();

  if (!title || !body) return;

  const audience: { scope: string; value?: string } = { scope };
  if (scope !== "all" && scopeValue) audience.value = scopeValue;

  await rpc("admin_send_broadcast", {
    p_title: title,
    p_body: body,
    p_urgency: urgency,
    p_audience: audience,
    p_scheduled_for: scheduledFor ? new Date(scheduledFor).toISOString() : null,
    p_expires_at: expiresAt ? new Date(expiresAt).toISOString() : null,
  });
  revalidatePath("/broadcasts");
}

async function deactivateAction(formData: FormData) {
  "use server";
  const id = String(formData.get("broadcast_id") ?? "");
  if (!id) return;
  const db = createAdminClient();
  await db.from("broadcasts").update({ is_active: false }).eq("broadcast_id", id);
  await audit("broadcast.deactivate", {
    targetType: "broadcast",
    targetId: id,
    after: { is_active: false },
  });
  revalidatePath("/broadcasts");
}

export default async function BroadcastsPage() {
  const db = createAdminClient();
  const { data, error } = await db
    .from("broadcasts")
    .select(
      "broadcast_id, title, body, urgency, audience, scheduled_for, sent_at, expires_at, delivered_count, dismissed_count, is_active, created_at"
    )
    .order("created_at", { ascending: false })
    .limit(100);
  const rows = (data ?? []) as Row[];
  const active = rows.filter(
    (r) =>
      r.is_active &&
      (r.sent_at || r.scheduled_for) &&
      (!r.expires_at || new Date(r.expires_at).getTime() > Date.now())
  );
  const scheduled = rows.filter(
    (r) => r.scheduled_for && !r.sent_at && r.is_active
  );
  const past = rows.filter((r) => !active.includes(r) && !scheduled.includes(r));

  return (
    <div className="flex flex-col gap-6 max-w-[1100px]">
      <PageHeader
        eyebrow="Operate"
        title="Broadcasts"
        subtitle="Reach the whole platform, a region, a tribe, or a role. Crisis-tier broadcasts pin a banner at the top of the mobile app."
      />

      {error && (
        <Card padded>
          <p className="text-sm text-danger">
            Could not load broadcasts: {error.message}
          </p>
        </Card>
      )}

      <Card title="Compose" padded>
        <form action={sendBroadcastAction} className="grid grid-cols-1 gap-3">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
            <div className="md:col-span-2">
              <label className="h-eyebrow block mb-1">Title</label>
              <input
                name="title"
                required
                className="input"
                maxLength={120}
                placeholder="Brief headline users will see first"
              />
            </div>
            <div>
              <label className="h-eyebrow block mb-1">Urgency</label>
              <select name="urgency" className="select w-full" defaultValue="info">
                <option value="info">info</option>
                <option value="warning">warning</option>
                <option value="critical">critical</option>
                <option value="crisis">crisis</option>
              </select>
            </div>
          </div>
          <div>
            <label className="h-eyebrow block mb-1">Body</label>
            <textarea
              name="body"
              required
              className="textarea"
              rows={4}
              maxLength={1000}
              placeholder="What do users need to know? Keep it short and human."
            />
          </div>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
            <div>
              <label className="h-eyebrow block mb-1">Audience</label>
              <select name="scope" className="select w-full" defaultValue="all">
                <option value="all">Everyone</option>
                <option value="region">Region (ISO code)</option>
                <option value="tribe">Tribe (slug)</option>
                <option value="role">Role</option>
              </select>
            </div>
            <div className="md:col-span-2">
              <label className="h-eyebrow block mb-1">Audience value</label>
              <input
                name="scope_value"
                className="input"
                placeholder="e.g. RW, /healing, moderator"
              />
            </div>
          </div>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            <div>
              <label className="h-eyebrow block mb-1">Schedule for (optional)</label>
              <input
                type="datetime-local"
                name="scheduled_for"
                className="input"
              />
            </div>
            <div>
              <label className="h-eyebrow block mb-1">Expires at (optional)</label>
              <input
                type="datetime-local"
                name="expires_at"
                className="input"
              />
            </div>
          </div>
          <div className="flex items-center gap-3 pt-2 border-t border-line mt-2">
            <button type="submit" className="btn-primary">
              <Megaphone size={14} />
              Send
            </button>
            <p className="text-xs text-ink-muted">
              Empty schedule = send immediately. Audited as <code className="font-mono">broadcast.send</code>.
            </p>
          </div>
        </form>
      </Card>

      <Section title="Active" rows={active} onDeactivate={deactivateAction} kind="active" />
      <Section title="Scheduled" rows={scheduled} onDeactivate={deactivateAction} kind="scheduled" />
      <Section title="Past" rows={past} onDeactivate={deactivateAction} kind="past" />
    </div>
  );
}

function Section({
  title,
  rows,
  onDeactivate,
  kind,
}: {
  title: string;
  rows: Row[];
  onDeactivate: (fd: FormData) => Promise<void>;
  kind: "active" | "scheduled" | "past";
}) {
  if (rows.length === 0) {
    if (kind === "active") {
      return (
        <Card title={title} padded>
          <EmptyState
            icon={<Megaphone size={28} />}
            title="No active broadcasts."
            hint="Send one above. Users see it on the next app open."
          />
        </Card>
      );
    }
    return null;
  }
  return (
    <Card title={title} padded={false}>
      <ul className="divide-y divide-line">
        {rows.map((r) => (
          <li key={r.broadcast_id} className="px-5 py-4">
            <div className="flex items-start gap-3">
              <UrgencyIcon urgency={r.urgency} />
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 flex-wrap">
                  <p className="font-extrabold text-burgundy">{r.title}</p>
                  <Badge tone={urgencyTone(r.urgency)}>{r.urgency}</Badge>
                  <AudiencePill audience={r.audience} />
                  {!r.is_active && <Badge tone="neutral">deactivated</Badge>}
                </div>
                <p className="text-sm text-burgundy/90 mt-1 whitespace-pre-wrap">
                  {r.body}
                </p>
                <p className="text-[11px] text-ink-muted mt-2">
                  {r.sent_at
                    ? `sent ${new Date(r.sent_at).toLocaleString()}`
                    : r.scheduled_for
                      ? `scheduled for ${new Date(r.scheduled_for).toLocaleString()}`
                      : `created ${new Date(r.created_at).toLocaleString()}`}
                  {r.expires_at &&
                    ` · expires ${new Date(r.expires_at).toLocaleString()}`}
                  {" · "}
                  {r.delivered_count.toLocaleString()} delivered
                  {r.dismissed_count > 0 &&
                    ` · ${r.dismissed_count.toLocaleString()} dismissed`}
                </p>
              </div>
              {r.is_active && (
                <form action={onDeactivate}>
                  <input type="hidden" name="broadcast_id" value={r.broadcast_id} />
                  <button type="submit" className="btn-ghost">
                    Deactivate
                  </button>
                </form>
              )}
            </div>
          </li>
        ))}
      </ul>
    </Card>
  );
}

function urgencyTone(u: Row["urgency"]): "ok" | "warn" | "danger" | "info" | "crisis" {
  switch (u) {
    case "info":
      return "info";
    case "warning":
      return "warn";
    case "critical":
      return "danger";
    case "crisis":
      return "crisis";
  }
}

function UrgencyIcon({ urgency }: { urgency: Row["urgency"] }) {
  const cls =
    urgency === "crisis"
      ? "text-danger"
      : urgency === "critical"
        ? "text-danger"
        : urgency === "warning"
          ? "text-warn"
          : "text-info";
  if (urgency === "crisis")
    return <Heart size={18} className={cls} fill="currentColor" />;
  if (urgency === "critical" || urgency === "warning")
    return <AlertTriangle size={18} className={cls} />;
  return <Info size={18} className={cls} />;
}

function AudiencePill({ audience }: { audience: Row["audience"] }) {
  const a = audience ?? { scope: "all" };
  if (a.scope === "all") return <Badge tone="neutral">everyone</Badge>;
  return (
    <Badge tone="neutral">
      {a.scope}
      {a.value ? `: ${a.value}` : ""}
    </Badge>
  );
}
