// space-summary-batch
//
// AI Space Assistant — daily summary + suggested prompt per Space.
//
// Designed for million-user scale:
//
//   * Batched + idempotent. Each invocation picks the top N Spaces
//     with new vents in the last 24h that don't yet have today's
//     summary (`pick_spaces_for_summary` RPC). UNIQUE
//     (space_id, for_date) makes concurrent invocations safe.
//
//   * Cost-bounded. Empty Spaces are filtered server-side so we
//     never spend Groq tokens on dead rooms. Vent corpus is
//     truncated to 25 most-recent vents x 280 chars each so the
//     prompt size is predictable.
//
//   * Concurrency-capped. We pool through a Promise.all with a
//     ceiling of `MAX_CONCURRENCY`, sitting safely under Groq's
//     RPM. The cron can fire every 5–15 min; whichever Spaces
//     don't fit in this batch will be picked up next tick.
//
//   * Fail-soft per row. One Groq error doesn't poison the batch.
//     The row is left without a summary and re-eligible on the
//     next tick.
//
// Schedule: trigger every 15 minutes via pg_cron, e.g.
//   SELECT cron.schedule(
//     'space_summary_15m',
//     '*/15 * * * *',
//     $$ SELECT net.http_post(
//          url := 'https://<project>.functions.supabase.co/space-summary-batch',
//          headers := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.functions_secret')),
//          body := jsonb_build_object('batch', 50)
//     ) $$
//   );
//
// Env:
//   GROQ_API_KEY                 — required; chat completion call
//   GROQ_SUMMARY_MODEL           — optional; defaults to llama-3.1-8b-instant
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY

import { adminClient } from '../_shared/supabase.ts';
import { corsHeaders, handleOptions } from '../_shared/cors.ts';

const GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';
const DEFAULT_MODEL =
  Deno.env.get('GROQ_SUMMARY_MODEL') ?? 'llama-3.1-8b-instant';
const MAX_CONCURRENCY = 5;

interface SpaceRow {
  space_id: string;
  tribe_id: string;
  name: string;
  vents_today: number;
}

interface VentRow {
  post_id: string;
  content: string;
  post_mood: string;
  created_at: string;
}

interface GroqSummary {
  summary: string;
  top_topics: string[];
  suggested_prompt: string;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return handleOptions()!;

  const groqKey = Deno.env.get('GROQ_API_KEY');
  if (!groqKey) {
    return json({ error: 'GROQ_API_KEY not configured' }, 500);
  }

  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  const batchSize = clamp(
    typeof body?.batch === 'number' ? body.batch : 50,
    1,
    200,
  );

  const sb = adminClient();

  // 1) Pick the top N eligible Spaces.
  const { data: spaces, error: pickErr } = await sb
    .rpc('pick_spaces_for_summary', { p_batch: batchSize });
  if (pickErr) {
    return json({ error: `pick_spaces_for_summary: ${pickErr.message}` }, 500);
  }
  const rows = (spaces ?? []) as SpaceRow[];
  if (rows.length === 0) {
    return json({ ok: true, processed: 0, skipped: 0 });
  }

  // 2) Process with bounded concurrency.
  let processed = 0;
  let failed = 0;
  await runPool(rows, MAX_CONCURRENCY, async (row) => {
    try {
      await summarizeOne(sb, row, groqKey);
      processed++;
    } catch (e) {
      failed++;
      console.error(
        `space-summary-batch[${row.space_id}] failed:`,
        e instanceof Error ? e.message : e,
      );
    }
  });

  return json({ ok: true, processed, failed, picked: rows.length });
});

async function summarizeOne(
  sb: ReturnType<typeof adminClient>,
  row: SpaceRow,
  groqKey: string,
): Promise<void> {
  // Pull a small, bounded vent corpus from the last 24h.
  const { data: vents, error: corpusErr } = await sb.rpc(
    'collect_space_vent_corpus',
    { p_space_id: row.space_id, p_limit: 25 },
  );
  if (corpusErr) throw new Error(`collect_corpus: ${corpusErr.message}`);
  const corpus = (vents ?? []) as VentRow[];
  if (corpus.length === 0) return; // race: nothing left to summarize.

  const result = await callGroq(row, corpus, groqKey);

  // UPSERT — `ON CONFLICT (space_id, for_date) DO UPDATE` lets the
  // worker re-try cleanly if the row was placeholder-inserted earlier.
  const { error: upsertErr } = await sb.from('space_summaries').upsert(
    {
      space_id: row.space_id,
      // The DB default already pins for_date to today UTC; sending
      // it here makes the upsert explicit and avoids surprises if the
      // cron schedule straddles midnight.
      for_date: utcDateString(),
      summary: result.summary,
      top_topics: result.top_topics,
      suggested_prompt: result.suggested_prompt,
      vents_analyzed: corpus.length,
      model: DEFAULT_MODEL,
      generated_at: new Date().toISOString(),
    },
    { onConflict: 'space_id,for_date' },
  );
  if (upsertErr) throw new Error(`upsert: ${upsertErr.message}`);
}

async function callGroq(
  row: SpaceRow,
  corpus: VentRow[],
  apiKey: string,
): Promise<GroqSummary> {
  // Compact rendering so the prompt scales — each line is one vent
  // with mood + truncated content.
  const ventLines = corpus
    .map((v) => `- [${v.post_mood}] ${v.content.replace(/\s+/g, ' ').trim()}`)
    .join('\n');

  const system =
    'You are the AI Space Assistant inside Venttly, an anonymous emotional-support app for Gen Z. ' +
    'You read the last 24h of vents in one Space and write a short, caring daily digest. ' +
    'Tone: warm, validating, never preachy. Never quote vents verbatim or expose identities. ' +
    'Respond as strict JSON matching the schema given by the user. No prose outside the JSON.';

  const user =
    `Space: ${row.name}\nVents today: ${corpus.length}\n\nRecent vents:\n${ventLines}\n\n` +
    `Return STRICT JSON with exactly these keys:\n` +
    `{\n` +
    `  "summary": "2-4 sentences capturing what people are feeling today, in plain English",\n` +
    `  "top_topics": ["array", "of", "1-5", "lowercase", "themes"],\n` +
    `  "suggested_prompt": "one question the keeper could post to spark the next conversation"\n` +
    `}`;

  const res = await fetch(GROQ_URL, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: DEFAULT_MODEL,
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: user },
      ],
      response_format: { type: 'json_object' },
      temperature: 0.5,
      max_tokens: 400,
    }),
  });

  if (!res.ok) {
    const txt = await res.text().catch(() => '');
    throw new Error(`groq ${res.status}: ${txt.slice(0, 200)}`);
  }

  const payload = await res.json();
  const raw = payload?.choices?.[0]?.message?.content as string | undefined;
  if (!raw) throw new Error('groq: no content');

  let parsed: Partial<GroqSummary>;
  try {
    parsed = JSON.parse(raw) as Partial<GroqSummary>;
  } catch {
    throw new Error(`groq: invalid JSON: ${raw.slice(0, 120)}`);
  }

  return {
    summary: typeof parsed.summary === 'string' ? parsed.summary : '',
    top_topics: Array.isArray(parsed.top_topics)
      ? parsed.top_topics.map((s) => String(s).slice(0, 40)).slice(0, 5)
      : [],
    suggested_prompt:
      typeof parsed.suggested_prompt === 'string'
        ? parsed.suggested_prompt
        : '',
  };
}

// ─── Helpers ────────────────────────────────────────────────────────

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(Math.max(n, lo), hi);
}

function utcDateString(): string {
  return new Date().toISOString().slice(0, 10);
}

/// Fixed-concurrency pool — N workers chew through items in order.
async function runPool<T>(
  items: T[],
  concurrency: number,
  worker: (item: T) => Promise<void>,
): Promise<void> {
  let i = 0;
  const runners = new Array(Math.min(concurrency, items.length))
    .fill(null)
    .map(async () => {
      while (i < items.length) {
        const idx = i++;
        await worker(items[idx]);
      }
    });
  await Promise.all(runners);
}
