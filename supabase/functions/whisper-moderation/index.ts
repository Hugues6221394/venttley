// whisper-moderation
//
// Triggered on INSERT into `whispers`. Runs the audio + metadata
// through the safety pipeline:
//   1. Title/description Tier-1 keyword scan (reusing the moderation
//      service's word lists).
//   2. (Future) Audio transcription via OpenAI Whisper or Groq Whisper.
//   3. (Future) Tier-2 LLM verdict on the transcript.
//
// For now this function ships the orchestration scaffolding and the
// metadata scan. The audio-transcription step is left as a TODO so
// it can be wired when an STT key is provisioned.
//
// Env:
//   GROQ_API_KEY         — optional; used for transcription + Tier-2
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY

import { adminClient } from '../_shared/supabase.ts';
import { corsHeaders, handleOptions } from '../_shared/cors.ts';

// Minimal Tier-1 keyword list — keep in sync with the Flutter
// moderation_service.dart for consistent verdicts.
const HARD_BLOCK = [
  'kill myself', 'kms', 'kill yourself', 'ks', 'doxx',
];
const SOFT_FLAG = [
  'suicide', 'self harm', 'self-harm', 'overdose',
];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return handleOptions()!;

  const payload = await req.json().catch(() => null);
  if (!payload?.record) return new Response('no record', { status: 400, headers: corsHeaders });

  const whisper = payload.record as {
    whisper_id: string;
    title?: string;
    description?: string;
    author_id?: string;
  };
  const text = `${whisper.title ?? ''} ${whisper.description ?? ''}`.toLowerCase();

  let crisis: 'elevated' | 'high' | null = null;
  if (HARD_BLOCK.some((k) => text.includes(k))) crisis = 'high';
  else if (SOFT_FLAG.some((k) => text.includes(k))) crisis = 'elevated';

  if (crisis) {
    const supabase = adminClient();
    await supabase
      .from('whispers')
      .update({ crisis_level: crisis })
      .eq('whisper_id', whisper.whisper_id);
  }

  // TODO: audio transcription via Groq Whisper-large-v3:
  //   const transcript = await transcribeAudio(whisper.audio_url);
  //   run Tier-2 LlamaGuard on transcript → set crisis_level / hide if blocked
  //
  // Until that ships, only the title/description scan runs.

  return new Response(JSON.stringify({ crisis_level: crisis }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});
