// Privacy-preserving daily Space summaries.
//
// The worker receives only aggregate mood counts from Postgres. It never reads
// vent bodies and makes no third-party AI request. The operation is batched,
// idempotent by (space_id, for_date), and bounded for predictable cost.
//
// Auth: verify_jwt=false plus x-cron-secret: <CRON_SECRET>.
// Rollout: SPACE_SUMMARIES_ENABLED must be explicitly enabled.

import { adminClient } from "../_shared/supabase.ts";
import {
  rolloutEnabled,
  verifyInternalSecret,
} from "../_shared/internal_auth.ts";
import { buildSummary, type MoodRow } from "./summary.ts";

const MAX_CONCURRENCY = 5;
const MODEL = "local-mood-v1";

interface SpaceRow {
  space_id: string;
  tribe_id: string;
  name: string;
  vents_today: number;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const auth = verifyInternalSecret(request, {
    envName: "CRON_SECRET",
    headerName: "x-cron-secret",
  });
  if (!auth.ok) return json({ error: auth.error }, auth.status);
  if (!rolloutEnabled("SPACE_SUMMARIES_ENABLED")) {
    return json({ ok: false, disabled: true }, 503);
  }

  const body = await request.json().catch(
    () => ({} as Record<string, unknown>),
  );
  const batchSize = clamp(
    typeof body?.batch === "number" ? body.batch : 50,
    1,
    200,
  );
  const supabase = adminClient();
  const picked = await supabase.rpc("pick_spaces_for_summary", {
    p_batch: batchSize,
  });
  if (picked.error) return json({ error: "pick_spaces_failed" }, 500);

  const spaces = (picked.data ?? []) as SpaceRow[];
  let processed = 0;
  let failed = 0;
  await runPool(spaces, MAX_CONCURRENCY, async (space) => {
    try {
      await summarizeOne(supabase, space);
      processed++;
    } catch (error) {
      failed++;
      console.error(
        `space summary failed [${space.space_id}]`,
        error instanceof Error ? error.message : "unknown_error",
      );
    }
  });

  return json({ ok: true, picked: spaces.length, processed, failed });
});

async function summarizeOne(
  supabase: ReturnType<typeof adminClient>,
  space: SpaceRow,
): Promise<void> {
  const counts = await supabase.rpc("collect_space_mood_counts", {
    p_space_id: space.space_id,
  });
  if (counts.error) throw new Error("collect_mood_counts_failed");
  const moods = ((counts.data ?? []) as MoodRow[])
    .filter((row) => typeof row.post_mood === "string" && row.vent_count > 0)
    .sort((left, right) => right.vent_count - left.vent_count);
  const total = moods.reduce((sum, row) => sum + row.vent_count, 0);
  if (total === 0) return;

  const result = buildSummary(total, moods);
  const write = await supabase.from("space_summaries").upsert(
    {
      space_id: space.space_id,
      for_date: utcDateString(),
      summary: result.summary,
      top_topics: result.topMoods,
      suggested_prompt: result.prompt,
      vents_analyzed: total,
      model: MODEL,
      generated_at: new Date().toISOString(),
    },
    { onConflict: "space_id,for_date" },
  );
  if (write.error) throw new Error("summary_upsert_failed");
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(Math.trunc(value), minimum), maximum);
}

function utcDateString(): string {
  return new Date().toISOString().slice(0, 10);
}

async function runPool<T>(
  items: T[],
  concurrency: number,
  worker: (item: T) => Promise<void>,
): Promise<void> {
  let next = 0;
  const runners = Array.from(
    { length: Math.min(concurrency, items.length) },
    async () => {
      while (next < items.length) {
        const index = next++;
        await worker(items[index]);
      }
    },
  );
  await Promise.all(runners);
}
