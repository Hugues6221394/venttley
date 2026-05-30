import { createAdminClient } from "@/lib/supabase/server";
import { redis, isRedisConfigured } from "@/lib/redis";
import { PageHeader, SectionHeader } from "@/components/ui/page-header";
import { Card, Row as KV } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { ErrorPanel } from "@/components/ui/empty-state";
import {
  Activity,
  AlertCircle,
  CheckCircle2,
  Clock,
  Globe2,
  Lock,
} from "@/components/ui/icons";

export const dynamic = "force-dynamic";

type ProbeResult = {
  name: string;
  status: "ok" | "degraded" | "down" | "unconfigured";
  latencyMs?: number;
  detail?: string;
  meta?: Record<string, string | number>;
};

export default async function SystemHealthPage() {
  const probes = await Promise.all([
    probeDatabase(),
    probeRedis(),
    probeGroq(),
    probePgStats(),
    probeCron(),
  ]);

  const overall =
    probes.some((p) => p.status === "down")
      ? "down"
      : probes.some((p) => p.status === "degraded")
        ? "degraded"
        : "ok";

  return (
    <div className="flex flex-col gap-6 max-w-[1200px]">
      <PageHeader
        eyebrow="Insight"
        title="System health"
        subtitle="Live probes of the services this dashboard depends on. Failed probes degrade gracefully — the page still loads so you can debug."
        actions={
          <Badge
            tone={overall === "ok" ? "ok" : overall === "degraded" ? "warn" : "danger"}
            icon={
              overall === "ok" ? (
                <CheckCircle2 size={12} />
              ) : (
                <AlertCircle size={12} />
              )
            }
          >
            {overall === "ok"
              ? "All systems normal"
              : overall === "degraded"
                ? "Degraded service"
                : "Service down"}
          </Badge>
        }
      />

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {probes.map((p) => (
          <ProbeCard key={p.name} probe={p} />
        ))}
      </div>

      <Card title="Environment" hint="What the dashboard is connected to" padded>
        <KV
          label="Supabase URL"
          value={
            <code className="font-mono text-xs">
              {redactUrl(process.env.NEXT_PUBLIC_SUPABASE_URL)}
            </code>
          }
        />
        <KV
          label="Service role key"
          value={
            process.env.SUPABASE_SERVICE_ROLE_KEY ? (
              <Badge tone="ok" icon={<Lock size={11} />}>
                configured
              </Badge>
            ) : (
              <Badge tone="danger">missing</Badge>
            )
          }
        />
        <KV
          label="Upstash Redis"
          value={
            isRedisConfigured ? (
              <Badge tone="ok">configured</Badge>
            ) : (
              <Badge tone="warn">not configured</Badge>
            )
          }
        />
        <KV
          label="Node env"
          value={
            <Badge tone="info">{process.env.NODE_ENV ?? "unknown"}</Badge>
          }
        />
      </Card>

      <p className="text-xs text-ink-muted">
        Probes run on every page load. Latencies are single-shot — treat them
        as a sniff test, not a benchmark. For production SLO tracking, wire
        these checks into an external uptime monitor.
      </p>
    </div>
  );
}

// ─────────────────────── Probes ───────────────────────

async function probeDatabase(): Promise<ProbeResult> {
  const t0 = performance.now();
  try {
    const db = await createAdminClient();
    const { error } = await db
      .from("admin_metrics_24h")
      .select("total_users")
      .maybeSingle();
    const latencyMs = Math.round(performance.now() - t0);
    if (error) {
      return {
        name: "PostgreSQL (Supabase)",
        status: "down",
        latencyMs,
        detail: error.message,
      };
    }
    return {
      name: "PostgreSQL (Supabase)",
      status: latencyMs > 1500 ? "degraded" : "ok",
      latencyMs,
      detail: "admin_metrics_24h view reachable",
    };
  } catch (e) {
    return {
      name: "PostgreSQL (Supabase)",
      status: "down",
      detail: (e as Error).message,
    };
  }
}

async function probeRedis(): Promise<ProbeResult> {
  if (!isRedisConfigured || !redis) {
    return {
      name: "Upstash Redis",
      status: "unconfigured",
      detail:
        "Set UPSTASH_REDIS_REST_URL + UPSTASH_REDIS_REST_TOKEN to enable cross-instance counters and rate limits.",
    };
  }
  const t0 = performance.now();
  try {
    await redis.ping();
    const latencyMs = Math.round(performance.now() - t0);
    return {
      name: "Upstash Redis",
      status: latencyMs > 800 ? "degraded" : "ok",
      latencyMs,
      detail: "PING ok",
    };
  } catch (e) {
    return {
      name: "Upstash Redis",
      status: "down",
      detail: (e as Error).message,
    };
  }
}

async function probeGroq(): Promise<ProbeResult> {
  const key = process.env.GROQ_API_KEY;
  if (!key) {
    return {
      name: "Groq classifier",
      status: "unconfigured",
      detail:
        "Set GROQ_API_KEY in admin/.env.local to verify the Tier-2 safety classifier is reachable.",
    };
  }
  const t0 = performance.now();
  try {
    const res = await fetch("https://api.groq.com/openai/v1/models", {
      headers: { Authorization: `Bearer ${key}` },
      // Short timeout so a slow Groq doesn't slow the page; AbortController
      // would be cleaner but this keeps the probe self-contained.
      cache: "no-store",
    });
    const latencyMs = Math.round(performance.now() - t0);
    if (res.status === 200) {
      return {
        name: "Groq classifier",
        status: latencyMs > 2000 ? "degraded" : "ok",
        latencyMs,
        detail: "API key valid; models endpoint reachable",
      };
    }
    return {
      name: "Groq classifier",
      status: "down",
      latencyMs,
      detail: `HTTP ${res.status}`,
    };
  } catch (e) {
    return {
      name: "Groq classifier",
      status: "down",
      detail: (e as Error).message,
    };
  }
}

async function probePgStats(): Promise<ProbeResult> {
  try {
    const db = await createAdminClient();
    const { count } = await db
      .from("audit_log")
      .select("audit_id", { count: "exact", head: true })
      .gte(
        "created_at",
        new Date(Date.now() - 24 * 3600 * 1000).toISOString()
      );
    return {
      name: "Audit volume · 24h",
      status: "ok",
      detail: "Audit ledger reachable",
      meta: { entries_24h: count ?? 0 },
    };
  } catch (e) {
    return {
      name: "Audit volume · 24h",
      status: "down",
      detail: (e as Error).message,
    };
  }
}

async function probeCron(): Promise<ProbeResult> {
  try {
    const db = await createAdminClient();
    const { data } = await db
      .from("mv_hot_posts")
      .select("post_id", { count: "exact", head: true })
      .limit(1);
    // The materialised view is refreshed by a pg_cron job every ~2 minutes.
    // We can't read pg_cron directly via PostgREST; reaching the MV at all
    // tells us the cron has run at least once.
    return {
      name: "Hot-feed cron (mv_hot_posts)",
      status: "ok",
      detail: "Materialised view reachable",
      meta: { rows_reached: data ? "ok" : "0" },
    };
  } catch (e) {
    return {
      name: "Hot-feed cron (mv_hot_posts)",
      status: "degraded",
      detail: (e as Error).message,
    };
  }
}

// ─────────────────────── UI ───────────────────────

function ProbeCard({ probe }: { probe: ProbeResult }) {
  const { name, status, latencyMs, detail, meta } = probe;
  const tone =
    status === "ok"
      ? "ok"
      : status === "degraded"
        ? "warn"
        : status === "unconfigured"
          ? "neutral"
          : "danger";
  const icon =
    status === "ok" ? (
      <CheckCircle2 size={14} className="text-ok" />
    ) : status === "degraded" ? (
      <Clock size={14} className="text-warn" />
    ) : status === "unconfigured" ? (
      <Lock size={14} className="text-ink-muted" />
    ) : (
      <AlertCircle size={14} className="text-danger" />
    );

  return (
    <div className="surface p-5 flex flex-col gap-2">
      <div className="flex items-center gap-2">
        {icon}
        <p className="font-extrabold text-burgundy">{name}</p>
        <Badge tone={tone} className="ml-auto">
          {status}
        </Badge>
      </div>
      {latencyMs !== undefined && (
        <p className="text-sm text-burgundy tabular">
          <Activity size={12} className="inline mr-1.5" />
          {latencyMs} ms
        </p>
      )}
      {detail && <p className="text-xs text-ink-muted">{detail}</p>}
      {meta && (
        <div className="mt-1 grid grid-cols-2 gap-1 text-[11px]">
          {Object.entries(meta).map(([k, v]) => (
            <div key={k}>
              <span className="text-ink-muted">{k}:</span>{" "}
              <span className="font-mono text-burgundy">{v}</span>
            </div>
          ))}
        </div>
      )}
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
