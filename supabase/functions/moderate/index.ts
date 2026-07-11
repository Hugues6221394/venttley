// moderate
//
// Server-side Tier-2 safety classification (Groq Llama Guard). Two wins over
// calling Groq from the app:
//   1. The Groq API key lives in edge secrets, not shipped in the mobile app
//      (where it could be extracted and abused).
//   2. A trusted verdict cache (moderation_verdicts, migration 0091): identical
//      content is classified once, then served from cache — cheaper + faster at
//      scale, and un-poisonable because only this function (service role) writes.
//
// Returns the raw model verdict shape { verdict, categories, reason } so the
// client keeps its existing mapping (crisis handling, block→warn downgrade for
// self-harm). Fails open (verdict 'safe') on any error — Tier-1 still applies
// on-device.
//
// Auth: JWT verification ON. Env: GROQ_API_KEY, GROQ_GUARD_MODEL (optional).

import { adminClient } from '../_shared/supabase.ts';
import { corsHeaders, handleOptions } from '../_shared/cors.ts';

const SYSTEM_PROMPT =
  "You are Venttly's safety reviewer for an anonymous emotional-support app. " +
  'Read the user message and return ONLY a compact JSON object with keys: ' +
  'verdict ("safe"|"warn"|"block"), categories (array of any of ' +
  '"self_harm","hate","harassment","sexual_content","violence","privacy","other"), ' +
  'reason (one short sentence the user will read). Guidance: ' +
  '- block hate speech, harassment of others, sexual solicitation, doxxing, ' +
  'credible threats, sexual content involving minors. ' +
  '- warn (do NOT block) when the writer expresses self-harm or suicidal ' +
  'feelings — the user must still be able to reach out for help. ' +
  '- safe for emotional venting, sadness, anger, swearing, or descriptions of ' +
  'past trauma told in the first person.';

type Verdict = { verdict: string; categories: string[]; reason: string | null };

const SAFE: Verdict = { verdict: 'safe', categories: [], reason: null };

async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function normalize(text: string): string {
  return text.trim().toLowerCase().replace(/\s+/g, ' ');
}

async function classifyWithGroq(text: string): Promise<Verdict | null> {
  const key = Deno.env.get('GROQ_API_KEY');
  if (!key) return null; // No key → caller falls back to safe (Tier-1 stands).
  const model = Deno.env.get('GROQ_GUARD_MODEL') ?? 'llama-3.3-70b-versatile';
  try {
    const res = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        temperature: 0,
        max_tokens: 200,
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: SYSTEM_PROMPT },
          { role: 'user', content: text },
        ],
      }),
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) return null;
    const body = await res.json();
    const content = body?.choices?.[0]?.message?.content ?? '{}';
    const parsed = JSON.parse(content);
    const categories = Array.isArray(parsed.categories)
      ? parsed.categories.map((c: unknown) => String(c))
      : [];
    const verdict = ['safe', 'warn', 'block'].includes(parsed.verdict)
      ? parsed.verdict
      : 'safe';
    return { verdict, categories, reason: parsed.reason ?? null };
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return handleOptions()!;
  const headers = { ...corsHeaders, 'Content-Type': 'application/json' };
  if (!req.headers.get('Authorization')) {
    return new Response(JSON.stringify(SAFE), { status: 401, headers });
  }

  let text = '';
  try {
    text = String((await req.json())?.text ?? '');
  } catch {
    return new Response(JSON.stringify(SAFE), { status: 400, headers });
  }
  if (!text.trim()) return new Response(JSON.stringify(SAFE), { headers });

  const sb = adminClient();
  const hash = await sha256(normalize(text));

  // Cache hit → bump + serve.
  const { data: cached } = await sb
    .from('moderation_verdicts')
    .select('verdict, categories, reason')
    .eq('content_hash', hash)
    .maybeSingle();
  if (cached) {
    // Increment hit_count + touch last_seen so cache effectiveness is visible
    // on the Ops dashboard (migration 0093).
    await sb.rpc('bump_moderation_hit', { p_hash: hash });
    return new Response(
      JSON.stringify({
        verdict: cached.verdict,
        categories: cached.categories ?? [],
        reason: cached.reason,
        cached: true,
      }),
      { headers },
    );
  }

  // Miss → classify + store.
  const result = (await classifyWithGroq(text)) ?? SAFE;
  const crisis = result.categories.includes('self_harm');
  await sb.from('moderation_verdicts').upsert(
    {
      content_hash: hash,
      verdict: result.verdict,
      categories: result.categories,
      reason: result.reason,
      crisis,
      last_seen_at: new Date().toISOString(),
    },
    { onConflict: 'content_hash' },
  );

  return new Response(JSON.stringify({ ...result, cached: false }), { headers });
});
