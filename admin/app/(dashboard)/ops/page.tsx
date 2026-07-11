import { createSsrClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { StatCard } from "@/components/ui/stat-card";

export const dynamic = "force-dynamic";

// Rough per-call cost of a Groq Llama Guard classification (USD). Adjust to
// your plan; used only for an at-a-glance spend *estimate*, clearly labelled.
const LLM_COST_PER_CALL = 0.0004;

type Snapshot = {
  moderation: {
    entries: number;
    total_lookups: number;
    safe: number;
    warn: number;
    block: number;
    classified_30d: number;
  };
  media: { blocked: number; sensitive: number; pending: number };
  abuse: { active_suspensions: number };
  volume_30d: {
    posts: number;
    comments: number;
    tribe_messages: number;
    dms: number;
    whispers: number;
  };
};

export default async function OpsPage() {
  const ssr = await createSsrClient();
  const { data } = await ssr.rpc("admin_ops_snapshot");
  const s = (data as Snapshot | null) ?? {
    moderation: { entries: 0, total_lookups: 0, safe: 0, warn: 0, block: 0, classified_30d: 0 },
    media: { blocked: 0, sensitive: 0, pending: 0 },
    abuse: { active_suspensions: 0 },
    volume_30d: { posts: 0, comments: 0, tribe_messages: 0, dms: 0, whispers: 0 },
  };

  const lookups = s.moderation.total_lookups;
  const entries = s.moderation.entries;
  // Cache hit-rate: lookups beyond the first (unique) classification were served
  // from cache — i.e. LLM calls we DIDN'T pay for.
  const cacheServed = Math.max(0, lookups - entries);
  const hitRate = lookups > 0 ? Math.round((cacheServed / lookups) * 100) : 0;

  const totalMessages =
    s.volume_30d.tribe_messages + s.volume_30d.dms;
  const totalContent =
    s.volume_30d.posts + s.volume_30d.comments + totalMessages + s.volume_30d.whispers;

  // Estimated LLM spend if EVERY moderated item had hit the model, vs actual
  // (only cache misses / first classifications). Shows the cache's savings.
  const estFullSpend = (lookups * LLM_COST_PER_CALL).toFixed(2);
  const estActualSpend = (s.moderation.classified_30d * LLM_COST_PER_CALL).toFixed(2);

  return (
    <div className="flex flex-col gap-6 max-w-[1200px]">
      <PageHeader
        eyebrow="Insight"
        title="Ops & cost"
        subtitle="Live operational health and unit-economics signals: moderation cache efficiency, media-safety throughput, abuse enforcement, and content volume driving spend."
      />

      {/* Moderation cache */}
      <Card title="Moderation cache" hint="Server-side Llama Guard verdict cache">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <StatCard label="Cache hit-rate" value={`${hitRate}%`} tone={hitRate >= 30 ? "ok" : "neutral"} sub="Calls served from cache" />
          <StatCard label="Unique classified" value={entries} sub="Distinct content" />
          <StatCard label="Total lookups" value={lookups} sub="Classify + cache hits" />
          <StatCard label="Classified · 30d" value={s.moderation.classified_30d} tone="info" />
        </div>
        <div className="grid grid-cols-3 gap-4 mt-4">
          <Metric label="Safe" value={s.moderation.safe} />
          <Metric label="Warn" value={s.moderation.warn} />
          <Metric label="Block" value={s.moderation.block} />
        </div>
      </Card>

      {/* Estimated LLM spend */}
      <Card title="Estimated moderation spend" hint={`Rough estimate @ $${LLM_COST_PER_CALL}/call — tune the constant to your plan`}>
        <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
          <StatCard label="Est. actual (30d)" value={`$${estActualSpend}`} tone="ok" sub="Cache misses only" />
          <StatCard label="Est. without cache" value={`$${estFullSpend}`} tone="neutral" sub="If every lookup hit the model" />
          <StatCard label="Est. saved by cache" value={`$${(Number(estFullSpend) - Number(estActualSpend)).toFixed(2)}`} tone="ok" />
        </div>
        <p className="text-xs text-ink-muted mt-3">
          Estimates only — for exact figures reconcile against your Groq + Supabase
          billing. The client-side cost gate also skips the model for clearly-benign
          messages, so real spend is lower still.
        </p>
      </Card>

      {/* Media safety + abuse */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Card title="Media safety" hint="Auto-moderation of images">
          <div className="grid grid-cols-3 gap-4">
            <Metric label="Blocked" value={s.media.blocked} tone="danger" />
            <Metric label="Sensitive" value={s.media.sensitive} tone="warn" />
            <Metric label="Pending scan" value={s.media.pending} />
          </div>
        </Card>
        <Card title="Abuse enforcement" hint="Live">
          <Metric label="Active suspensions" value={s.abuse.active_suspensions} tone={s.abuse.active_suspensions ? "warn" : "ok"} />
        </Card>
      </div>

      {/* Content volume */}
      <Card title="Content volume · 30d" hint="Load + moderation-spend drivers">
        <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
          <Metric label="Posts" value={s.volume_30d.posts} />
          <Metric label="Comments" value={s.volume_30d.comments} />
          <Metric label="Tribe msgs" value={s.volume_30d.tribe_messages} />
          <Metric label="DMs" value={s.volume_30d.dms} />
          <Metric label="Whispers" value={s.volume_30d.whispers} />
        </div>
        <p className="text-xs text-ink-muted mt-3 tabular">
          {totalContent.toLocaleString()} items in the last 30 days ·{" "}
          {totalMessages.toLocaleString()} messages.
        </p>
      </Card>
    </div>
  );
}

function Metric({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone?: "danger" | "warn" | "ok";
}) {
  const color =
    tone === "danger" ? "text-danger" : tone === "warn" ? "text-warn" : tone === "ok" ? "text-ok" : "text-burgundy";
  return (
    <div>
      <p className="h-eyebrow">{label}</p>
      <p className={`tabular text-2xl font-extrabold ${color}`}>
        {value.toLocaleString()}
      </p>
    </div>
  );
}
