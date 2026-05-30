import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Flag, Plus } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type Flag = {
  flag_key: string;
  description: string | null;
  enabled: boolean;
  rollout_pct: number;
  environment: string;
  updated_by: string | null;
  updated_at: string;
  created_at: string;
};

async function toggleFlagAction(formData: FormData) {
  "use server";
  const key = String(formData.get("flag_key") ?? "");
  const enabled = String(formData.get("enabled") ?? "") === "true";
  const rollout = Number(formData.get("rollout_pct") ?? 0);
  const reason = String(formData.get("reason") ?? "");
  await rpc("admin_set_flag", {
    p_key: key,
    p_enabled: enabled,
    p_rollout_pct: Number.isFinite(rollout) ? rollout : null,
    p_reason: reason || null,
  });
  revalidatePath("/flags");
}

async function createFlagAction(formData: FormData) {
  "use server";
  const key = String(formData.get("flag_key") ?? "").trim();
  const desc = String(formData.get("description") ?? "").trim();
  if (!key) return;
  // First write the row at false/0%, then a follow-up update can set the
  // description. admin_set_flag handles the upsert path and audit-logs.
  await rpc("admin_set_flag", {
    p_key: key,
    p_enabled: false,
    p_rollout_pct: 0,
    p_reason: `created: ${desc || "(no description)"}`,
  });
  if (desc) {
    // Description isn't surfaced through the RPC; set it directly. The
    // admin_set_flag call above already wrote an audit row that captures
    // the creation. No second audit needed.
    const db = await createAdminClient();
    await db
      .from("feature_flags")
      .update({ description: desc })
      .eq("flag_key", key);
  }
  revalidatePath("/flags");
}

export default async function FlagsPage() {
  const db = await createAdminClient();
  const { data, error } = await db
    .from("feature_flags")
    .select(
      "flag_key, description, enabled, rollout_pct, environment, updated_by, updated_at, created_at"
    )
    .order("flag_key");
  const flags = (data ?? []) as Flag[];

  return (
    <div className="flex flex-col gap-6 max-w-[1100px]">
      <PageHeader
        eyebrow="Control"
        title="Feature flags"
        subtitle="Ship dark, ramp gradually, or kill a feature without a deploy. Every flag change is audit-logged."
      />

      {error && (
        <Card padded>
          <p className="text-sm text-danger">
            Could not load flags: {error.message}
          </p>
        </Card>
      )}

      <Card title="Add a flag" padded>
        <form action={createFlagAction} className="flex gap-2">
          <input
            name="flag_key"
            placeholder="my_new_flag"
            className="input flex-1 font-mono"
            pattern="[a-z0-9_]+"
            required
          />
          <input
            name="description"
            placeholder="What does this flag gate?"
            className="input flex-[2]"
          />
          <button type="submit" className="btn-secondary">
            <Plus size={14} />
            Create
          </button>
        </form>
        <p className="text-[11px] text-ink-muted mt-2">
          Keys are <code className="font-mono">snake_case</code>. New flags
          start disabled at 0% rollout.
        </p>
      </Card>

      {flags.length === 0 ? (
        <Card padded>
          <EmptyState
            icon={<Flag size={32} />}
            title="No flags yet."
            hint="Create one above. Mobile clients read flags via public RLS so changes propagate without a deploy."
          />
        </Card>
      ) : (
        <ul className="flex flex-col gap-3">
          {flags.map((f) => (
            <FlagCard key={f.flag_key} flag={f} onToggle={toggleFlagAction} />
          ))}
        </ul>
      )}
    </div>
  );
}

function FlagCard({
  flag,
  onToggle,
}: {
  flag: Flag;
  onToggle: (fd: FormData) => Promise<void>;
}) {
  return (
    <li className="surface p-5">
      <div className="flex items-start gap-3">
        <Flag
          size={18}
          className={flag.enabled ? "text-ok mt-1" : "text-ink-muted mt-1"}
        />
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <code className="text-sm font-extrabold text-burgundy font-mono">
              {flag.flag_key}
            </code>
            <Badge tone={flag.enabled ? "ok" : "neutral"}>
              {flag.enabled ? "enabled" : "off"}
            </Badge>
            <Badge tone="info">{flag.rollout_pct}% rollout</Badge>
            <Badge tone="neutral">{flag.environment}</Badge>
          </div>
          {flag.description && (
            <p className="text-xs text-ink-muted mt-1">{flag.description}</p>
          )}
          <p className="text-[10px] text-ink-muted mt-1">
            updated {new Date(flag.updated_at).toLocaleString()}
          </p>
        </div>
      </div>

      <form action={onToggle} className="mt-4 flex flex-wrap items-end gap-2 pt-4 border-t border-line">
        <input type="hidden" name="flag_key" value={flag.flag_key} />
        <div>
          <label className="h-eyebrow block mb-1">State</label>
          <select
            name="enabled"
            className="select"
            defaultValue={flag.enabled ? "true" : "false"}
          >
            <option value="true">enabled</option>
            <option value="false">off</option>
          </select>
        </div>
        <div>
          <label className="h-eyebrow block mb-1">Rollout %</label>
          <input
            type="number"
            name="rollout_pct"
            min={0}
            max={100}
            defaultValue={flag.rollout_pct}
            className="input w-24 tabular"
          />
        </div>
        <div className="flex-1 min-w-[200px]">
          <label className="h-eyebrow block mb-1">Reason (audited)</label>
          <input
            type="text"
            name="reason"
            placeholder="e.g. ramp to 25% — telemetry looks healthy"
            className="input"
          />
        </div>
        <button type="submit" className="btn-primary">
          Apply
        </button>
      </form>
    </li>
  );
}
