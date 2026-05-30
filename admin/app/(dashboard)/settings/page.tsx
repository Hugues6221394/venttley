import Link from "next/link";
import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";
import { rpc } from "@/lib/audit";
import { isRedisConfigured } from "@/lib/redis";
import { PageHeader } from "@/components/ui/page-header";
import { Card, Row as KV } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import {
  AlertCircle,
  Lock,
  Activity,
  Flag,
  ShieldCheck,
} from "@/components/ui/icons";

export const dynamic = "force-dynamic";

async function setMaintenanceAction(formData: FormData) {
  "use server";
  const enabled = String(formData.get("enabled") ?? "") === "true";
  const reason = String(formData.get("reason") ?? "");
  await rpc("admin_set_flag", {
    p_key: "maintenance_mode",
    p_enabled: enabled,
    p_rollout_pct: enabled ? 100 : 0,
    p_reason: reason || null,
  });
  revalidatePath("/settings");
}

export default async function SettingsPage() {
  const db = createAdminClient();
  const { data: maintenance } = await db
    .from("feature_flags")
    .select("enabled, updated_at, updated_by")
    .eq("flag_key", "maintenance_mode")
    .maybeSingle();
  const maintenanceOn = !!maintenance?.enabled;

  const env = {
    supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL,
    serviceRole: !!process.env.SUPABASE_SERVICE_ROLE_KEY,
    anonKey: !!process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    redis: isRedisConfigured,
    groq: !!process.env.GROQ_API_KEY,
  };

  return (
    <div className="flex flex-col gap-6 max-w-[1100px]">
      <PageHeader
        eyebrow="Control"
        title="Settings"
        subtitle="High-leverage controls. Most live state lives in feature flags."
        actions={
          <Link href="/flags" className="btn-secondary">
            <Flag size={14} />
            All feature flags
          </Link>
        }
      />

      <Card title="Maintenance mode" padded>
        <p className="text-sm text-burgundy mb-4">
          When on, the mobile client shows a maintenance screen and read-only
          surfaces wherever possible. Use during deploys or DB migrations that
          would corrupt user writes.
        </p>
        <form action={setMaintenanceAction} className="flex flex-wrap items-end gap-3">
          <Badge tone={maintenanceOn ? "danger" : "ok"}>
            {maintenanceOn ? "ON" : "OFF"}
          </Badge>
          <input type="hidden" name="enabled" value={maintenanceOn ? "false" : "true"} />
          <input
            type="text"
            name="reason"
            placeholder={maintenanceOn ? "Resuming because…" : "Going into maintenance because…"}
            className="input flex-1 min-w-[260px]"
          />
          <button
            type="submit"
            className={maintenanceOn ? "btn-secondary" : "btn-danger"}
          >
            {maintenanceOn ? "Resume operations" : "Enter maintenance mode"}
          </button>
        </form>
        {maintenance?.updated_at && (
          <p className="text-[11px] text-ink-muted mt-3">
            Last toggled {new Date(maintenance.updated_at).toLocaleString()}
          </p>
        )}
      </Card>

      <Card title="Environment" hint="Variables this dashboard relies on" padded>
        <KV
          label="Supabase URL"
          value={<code className="font-mono text-xs">{redactUrl(env.supabaseUrl)}</code>}
        />
        <KV
          label="Service role key"
          value={
            env.serviceRole ? (
              <Badge tone="ok" icon={<Lock size={11} />}>configured</Badge>
            ) : (
              <Badge tone="danger" icon={<AlertCircle size={11} />}>missing</Badge>
            )
          }
        />
        <KV
          label="Anon key"
          value={env.anonKey ? <Badge tone="ok">configured</Badge> : <Badge tone="danger">missing</Badge>}
        />
        <KV
          label="Upstash Redis"
          value={env.redis ? <Badge tone="ok">configured</Badge> : <Badge tone="warn">not configured</Badge>}
        />
        <KV
          label="Groq classifier"
          value={env.groq ? <Badge tone="ok">configured</Badge> : <Badge tone="warn">not configured</Badge>}
        />
        <KV
          label="Node env"
          value={<Badge tone="info">{process.env.NODE_ENV ?? "unknown"}</Badge>}
        />
      </Card>

      <Card title="Policy & safety" hint="Configurable thresholds and behaviours" padded>
        <KV
          label="Tier-1 keyword block"
          value={<Badge tone="ok" icon={<ShieldCheck size={11} />}>active</Badge>}
          hint="Hate slurs, harassment, doxxing — blocked client-side before submit"
        />
        <KV
          label="Tier-2 LLM classifier"
          value={
            env.groq ? (
              <Badge tone="ok" icon={<ShieldCheck size={11} />}>active</Badge>
            ) : (
              <Badge tone="warn">disabled (no GROQ_API_KEY)</Badge>
            )
          }
          hint="Groq-hosted moderation pass for ambiguous content"
        />
        <KV
          label="Crisis banner"
          value={<Badge tone="ok">live</Badge>}
          hint="Surfaces helplines on posts the classifier tagged self-harm"
        />
        <KV
          label="Audit logging"
          value={<Badge tone="ok" icon={<ShieldCheck size={11} />}>immutable</Badge>}
          hint="audit_log has a BEFORE UPDATE/DELETE trigger that blocks mutation"
        />
        <p className="text-[11px] text-ink-muted mt-2">
          Per-feature thresholds live in <Link href="/flags" className="underline">feature flags</Link>.
        </p>
      </Card>

      <Card title="Healthchecks" hint="Open the dedicated panel for live probes" padded>
        <div className="flex items-center gap-2">
          <Activity size={14} className="text-berry" />
          <Link href="/system" className="text-sm font-semibold text-berry hover:underline">
            View live system health →
          </Link>
        </div>
      </Card>
    </div>
  );
}

function redactUrl(url?: string): string {
  if (!url) return "(not set)";
  try {
    const u = new URL(url);
    return `${u.protocol}//${u.host}`;
  } catch {
    return url;
  }
}
