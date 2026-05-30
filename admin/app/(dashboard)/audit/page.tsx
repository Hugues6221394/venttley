import Link from "next/link";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import {
  Download,
  ScrollText,
  Search,
} from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Row = {
  audit_id: string;
  actor_id: string | null;
  actor_pseudonym: string;
  actor_role: string;
  action: string;
  target_type: string | null;
  target_id: string | null;
  target_label: string | null;
  before_state: unknown;
  after_state: unknown;
  reason: string | null;
  metadata: Record<string, unknown> | null;
  ip: string | null;
  created_at: string;
};

const ACTION_PREFIXES = [
  "user.",
  "post.",
  "report.",
  "broadcast.",
  "flag.",
  "tribe.",
];

export default async function AuditPage({
  searchParams,
}: {
  searchParams: Promise<{
    actor?: string;
    action?: string;
    target_type?: string;
    target_id?: string;
    from?: string;
    to?: string;
    expand?: string;
  }>;
}) {
  const sp = await searchParams;
  const actor = sp.actor?.trim() ?? "";
  const action = sp.action?.trim() ?? "";
  const targetType = sp.target_type?.trim() ?? "";
  const targetId = sp.target_id?.trim() ?? "";
  const from = sp.from ?? "";
  const to = sp.to ?? "";
  const expand = sp.expand ?? "";

  const db = createAdminClient();
  let q = db
    .from("audit_log")
    .select(
      "audit_id, actor_id, actor_pseudonym, actor_role, action, target_type, target_id, target_label, before_state, after_state, reason, metadata, ip, created_at"
    )
    .order("created_at", { ascending: false })
    .limit(300);
  if (actor) q = q.ilike("actor_pseudonym", `%${actor}%`);
  if (action) q = q.ilike("action", `${action}%`);
  if (targetType) q = q.eq("target_type", targetType);
  if (targetId) q = q.eq("target_id", targetId);
  if (from) q = q.gte("created_at", new Date(from).toISOString());
  if (to) q = q.lte("created_at", new Date(to + "T23:59:59").toISOString());
  const { data, error } = await q;
  const rows = (data ?? []) as Row[];

  const exportSp = new URLSearchParams();
  if (actor) exportSp.set("actor", actor);
  if (action) exportSp.set("action", action);
  if (targetType) exportSp.set("target_type", targetType);
  if (targetId) exportSp.set("target_id", targetId);
  if (from) exportSp.set("from", from);
  if (to) exportSp.set("to", to);

  return (
    <div className="flex flex-col gap-6 max-w-[1300px]">
      <PageHeader
        eyebrow="Insight"
        title="Audit log"
        subtitle="Every privileged write on the platform. The table is append-only — a DB trigger blocks UPDATE/DELETE."
        actions={
          <Link
            href={`/api/admin/audit-export?${exportSp.toString()}`}
            className="btn-secondary"
          >
            <Download size={14} />
            Export CSV
          </Link>
        }
      />

      <Card padded>
        <form method="get" className="flex flex-wrap gap-3 items-end">
          <div className="flex-1 min-w-[180px]">
            <label className="h-eyebrow block mb-1">Actor</label>
            <div className="relative">
              <Search
                size={14}
                className="absolute left-3 top-1/2 -translate-y-1/2 text-ink-muted"
              />
              <input
                name="actor"
                className="input pl-9"
                placeholder="pseudonym"
                defaultValue={actor}
              />
            </div>
          </div>
          <div className="flex-1 min-w-[180px]">
            <label className="h-eyebrow block mb-1">Action prefix</label>
            <select name="action" className="select w-full" defaultValue={action}>
              <option value="">All</option>
              {ACTION_PREFIXES.map((p) => (
                <option key={p} value={p}>
                  {p}*
                </option>
              ))}
            </select>
          </div>
          <div>
            <label className="h-eyebrow block mb-1">Target type</label>
            <select
              name="target_type"
              className="select"
              defaultValue={targetType}
            >
              <option value="">Any</option>
              <option value="user">user</option>
              <option value="post">post</option>
              <option value="report">report</option>
              <option value="broadcast">broadcast</option>
              <option value="feature_flag">feature_flag</option>
              <option value="tribe">tribe</option>
            </select>
          </div>
          <div>
            <label className="h-eyebrow block mb-1">From</label>
            <input type="date" name="from" className="input w-36" defaultValue={from} />
          </div>
          <div>
            <label className="h-eyebrow block mb-1">To</label>
            <input type="date" name="to" className="input w-36" defaultValue={to} />
          </div>
          <button className="btn-secondary" type="submit">
            Apply
          </button>
          {(actor || action || targetType || from || to) && (
            <a href="/audit" className="btn-ghost">
              Clear
            </a>
          )}
        </form>
      </Card>

      {error && (
        <Card padded>
          <p className="text-sm text-danger">
            Could not load audit log: {error.message}
          </p>
        </Card>
      )}

      {rows.length === 0 ? (
        <Card padded>
          <EmptyState
            icon={<ScrollText size={32} />}
            title="No audit entries match the filter."
            hint="The audit log captures every action taken through the SECURITY DEFINER admin RPCs."
          />
        </Card>
      ) : (
        <Card padded={false}>
          <ul className="divide-y divide-line">
            {rows.map((r) => {
              const isExpanded = expand === r.audit_id;
              return (
                <li key={r.audit_id} className="px-5 py-3">
                  <div className="flex items-start gap-3">
                    <Badge tone={actionTone(r.action)}>{r.action}</Badge>
                    <div className="flex-1 min-w-0">
                      <p className="text-sm text-burgundy">
                        <span className="font-semibold">
                          @{r.actor_pseudonym}
                        </span>
                        <span className="text-ink-muted">
                          {" "}
                          ({r.actor_role}){r.target_label ? " → " : ""}
                        </span>
                        {r.target_label && (
                          <span className="font-mono text-xs">{r.target_label}</span>
                        )}
                      </p>
                      {r.reason && (
                        <p className="text-xs text-ink-muted italic">
                          “{r.reason}”
                        </p>
                      )}
                    </div>
                    <p className="text-[11px] text-ink-muted whitespace-nowrap">
                      {new Date(r.created_at).toLocaleString()}
                    </p>
                    <Link
                      href={`/audit?${buildExpandSp(sp, isExpanded ? "" : r.audit_id)}`}
                      className="btn-ghost"
                    >
                      {isExpanded ? "Hide" : "Inspect"}
                    </Link>
                  </div>

                  {isExpanded && (
                    <div className="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3">
                      <JsonBlock label="Before" data={r.before_state} />
                      <JsonBlock label="After" data={r.after_state} />
                      {r.metadata && Object.keys(r.metadata).length > 0 && (
                        <JsonBlock label="Metadata" data={r.metadata} />
                      )}
                      <div className="surface-flat p-3">
                        <p className="h-eyebrow mb-1">Context</p>
                        <p className="text-xs text-ink-muted">
                          target_type:{" "}
                          <span className="font-mono">
                            {r.target_type ?? "—"}
                          </span>
                          <br />
                          target_id:{" "}
                          <span className="font-mono">
                            {r.target_id ?? "—"}
                          </span>
                          <br />
                          ip:{" "}
                          <span className="font-mono">{r.ip ?? "—"}</span>
                          <br />
                          audit_id:{" "}
                          <span className="font-mono select-all">
                            {r.audit_id}
                          </span>
                        </p>
                      </div>
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        </Card>
      )}
      <p className="text-xs text-ink-muted">
        Returns the latest 300 entries matching the filter. Tighten the date
        range or filter by target_id for narrower results.
      </p>
    </div>
  );
}

function buildExpandSp(
  current: Record<string, string | undefined>,
  next: string
): string {
  const sp = new URLSearchParams();
  for (const [k, v] of Object.entries(current)) {
    if (v && k !== "expand") sp.set(k, v);
  }
  if (next) sp.set("expand", next);
  return sp.toString();
}

function JsonBlock({ label, data }: { label: string; data: unknown }) {
  if (data === null || data === undefined) {
    return (
      <div className="surface-flat p-3">
        <p className="h-eyebrow mb-1">{label}</p>
        <p className="text-xs text-ink-muted italic">empty</p>
      </div>
    );
  }
  let pretty: string;
  try {
    pretty = JSON.stringify(data, null, 2);
  } catch {
    pretty = String(data);
  }
  return (
    <div className="surface-flat p-3">
      <p className="h-eyebrow mb-1">{label}</p>
      <pre className="font-mono text-[11px] text-burgundy whitespace-pre-wrap max-h-48 overflow-y-auto">
        {pretty}
      </pre>
    </div>
  );
}

function actionTone(action: string): "ok" | "warn" | "danger" | "info" | "neutral" {
  if (action.includes("delete") || action.includes("ban") || action.includes("suspend"))
    return "danger";
  if (action.includes("restore") || action.includes("resolve")) return "ok";
  if (action.includes("flag") || action.includes("role") || action.includes("broadcast"))
    return "info";
  if (action.includes("warn") || action.includes("clear")) return "warn";
  return "neutral";
}
