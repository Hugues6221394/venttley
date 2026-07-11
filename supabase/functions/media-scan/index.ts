// media-scan
//
// Authoritative image safety check. Called after a user uploads an image
// (post or whisper). It classifies the image and writes the verdict back to
// the row via the service role:
//   * blocked   → nudity / explicit sexual content → a DB trigger sets
//                 deleted_at, so users NEVER see it.
//   * sensitive → borderline (suggestive / gore) → shown behind a warning veil.
//   * clean     → shown normally.
//
// Provider: Sightengine (nudity-2.1 + gore), a simple REST API — set
// SIGHTENGINE_USER / SIGHTENGINE_SECRET. If not configured, we FAIL SAFE and
// mark the media 'sensitive' (veiled), never 'clean' — nudity must not slip
// through unscanned.
//
// CSAM: Sightengine also offers a CSAM model (and PhotoDNA / Thorn Safer exist
// for hash-matching + NCMEC reporting). That requires separate vetted access;
// when enabled, a CSAM hit must be BLOCKED and reported — wire it in below at
// the marked TODO. Do not silently downgrade a CSAM signal.
//
// Auth: JWT verification ON. Any signed-in user may trigger a (re)scan; the
// verdict is computed here, never supplied by the caller, so it can't be spoofed.

import { adminClient } from '../_shared/supabase.ts';
import { corsHeaders, handleOptions } from '../_shared/cors.ts';

type Verdict = 'clean' | 'sensitive' | 'blocked';

function classify(nudity: Record<string, number>, gore: number): {
  verdict: Verdict;
  labels: Record<string, number>;
} {
  const sexual = Math.max(
    nudity.sexual_activity ?? 0,
    nudity.sexual_display ?? 0,
    nudity.erotica ?? 0,
  );
  const suggestive = nudity.suggestive ?? 0;

  let verdict: Verdict = 'clean';
  if (sexual >= 0.6 || gore >= 0.7) {
    verdict = 'blocked';
  } else if (sexual >= 0.3 || suggestive >= 0.5 || gore >= 0.4) {
    verdict = 'sensitive';
  }
  return { verdict, labels: { sexual, suggestive, gore } };
}

// Defensive extraction of a CSAM signal from the provider response. Sightengine
// exposes a dedicated (access-gated) CSAM model; enable it by setting
// SIGHTENGINE_CSAM=on and including its model in SIGHTENGINE_MODELS. We check a
// few possible response shapes so a provider tweak doesn't silently disable it.
function csamProb(body: Record<string, unknown>): number {
  const c = body.csam as Record<string, unknown> | undefined;
  const candidates = [
    (c?.match as Record<string, number> | undefined)?.prob,
    (c as Record<string, number> | undefined)?.prob,
    (body['minor'] as Record<string, number> | undefined)?.prob,
  ];
  return Math.max(0, ...candidates.map((n) => (typeof n === 'number' ? n : 0)));
}

async function scan(
  imageUrl: string,
): Promise<{ verdict: Verdict; labels: Record<string, unknown>; csam: boolean }> {
  const user = Deno.env.get('SIGHTENGINE_USER');
  const secret = Deno.env.get('SIGHTENGINE_SECRET');
  // Fail safe: no scanner configured → veil, never show unscanned nudity.
  if (!user || !secret) {
    return { verdict: 'sensitive', labels: { reason: 'scanner_not_configured' }, csam: false };
  }
  const models = Deno.env.get('SIGHTENGINE_MODELS') ?? 'nudity-2.1,gore';
  const api = new URL('https://api.sightengine.com/1.0/check.json');
  api.searchParams.set('url', imageUrl);
  api.searchParams.set('models', models);
  api.searchParams.set('api_user', user);
  api.searchParams.set('api_secret', secret);

  try {
    const res = await fetch(api, { signal: AbortSignal.timeout(6000) });
    const body = await res.json();
    if (body.status !== 'success') {
      return { verdict: 'sensitive', labels: { reason: 'scan_error', body }, csam: false };
    }
    // CSAM check first — a hit overrides everything and routes to the incident
    // pipeline (quarantine + mandated report), never a normal delete.
    if (Deno.env.get('SIGHTENGINE_CSAM') === 'on' && csamProb(body) >= 0.5) {
      return { verdict: 'blocked', labels: { csam: csamProb(body) }, csam: true };
    }
    const gore = body.gore?.prob ?? body.gore?.classes?.gory ?? 0;
    const { verdict, labels } = classify(body.nudity ?? {}, gore);
    return { verdict, labels, csam: false };
  } catch (_) {
    return { verdict: 'sensitive', labels: { reason: 'scan_exception' }, csam: false };
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return handleOptions()!;
  const headers = { ...corsHeaders, 'Content-Type': 'application/json' };

  if (!req.headers.get('Authorization')) {
    return new Response(JSON.stringify({ ok: false, error: 'no auth' }), {
      status: 401,
      headers,
    });
  }

  let payload: { kind?: string; id?: string; imageUrl?: string };
  try {
    payload = await req.json();
  } catch {
    return new Response(JSON.stringify({ ok: false, error: 'bad body' }), {
      status: 400,
      headers,
    });
  }
  const { kind, id, imageUrl } = payload;
  if ((kind !== 'post' && kind !== 'whisper') || !id || !imageUrl) {
    return new Response(JSON.stringify({ ok: false, error: 'missing fields' }), {
      status: 400,
      headers,
    });
  }

  const { verdict, labels, csam } = await scan(imageUrl);

  const sb = adminClient();
  const table = kind === 'post' ? 'posts' : 'whispers';
  const idCol = kind === 'post' ? 'post_id' : 'whisper_id';

  // CSAM hit → route to the incident pipeline: quarantine (preserve, don't
  // delete) + open a super-admin incident for mandated review/reporting.
  if (csam) {
    const { data: row } = await sb.from(table).select('author_id').eq(idCol, id).maybeSingle();
    const authorId = (row as Record<string, string> | null)?.author_id ?? null;
    await sb.rpc('record_csam_incident', {
      p_kind: kind,
      p_id: id,
      p_media_url: imageUrl,
      p_author: authorId,
      p_labels: labels,
    });
    return new Response(JSON.stringify({ ok: true, verdict: 'blocked', csam: true }), { headers });
  }

  const { error } = await sb
    .from(table)
    .update({ media_status: verdict, media_labels: labels })
    .eq(idCol, id);

  if (error) {
    return new Response(JSON.stringify({ ok: false, error: error.message }), {
      status: 500,
      headers,
    });
  }
  return new Response(JSON.stringify({ ok: true, verdict }), { headers });
});
