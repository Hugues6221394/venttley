// whisper-moderation
//
// Triggered on INSERT into `whispers`. Runs the audio + metadata
// through the safety pipeline:
//   1. Title/description Tier-1 keyword scan (reusing the moderation
//      service's word lists).
//   2. Canonical server-side metadata update.
//
// This function does not fetch or transmit Whisper audio. Any future
// transcription processor requires an approved privacy design, processor
// terms, disclosure, retention controls, and a separate opt-in rollout flag.
//
// Env: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY

import { adminClient } from "../_shared/supabase.ts";
import {
  rolloutEnabled,
  verifyInternalSecret,
} from "../_shared/internal_auth.ts";

// Minimal Tier-1 keyword list — keep in sync with the Flutter
// moderation_service.dart for consistent verdicts.
const HARD_BLOCK = [
  "kill myself",
  "kill yourself",
  "doxx",
];
const SOFT_FLAG = [
  "suicide",
  "self harm",
  "self-harm",
  "overdose",
];

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const auth = verifyInternalSecret(req, {
    envName: "WEBHOOK_SECRET",
    headerName: "x-webhook-secret",
  });
  if (!auth.ok) return json({ error: auth.error }, auth.status);
  if (!rolloutEnabled("WHISPER_MODERATION_ENABLED")) {
    return json({ ok: false, disabled: true }, 503);
  }

  const payload = await req.json().catch(() => null);
  const whisperId = payload?.record?.whisper_id;
  if (payload?.type !== "INSERT" || typeof whisperId !== "string") {
    return json({ error: "invalid_webhook_event" }, 400);
  }

  // The webhook body is only a pointer. Always moderate the canonical row so
  // a forged payload cannot change the crisis state of arbitrary content.
  const supabase = adminClient();
  const lookup = await supabase
    .from("whispers")
    .select("whisper_id, title, description")
    .eq("whisper_id", whisperId)
    .maybeSingle();
  if (lookup.error) return json({ error: "lookup_failed" }, 500);
  if (!lookup.data) return json({ error: "not_found" }, 404);
  const whisper = lookup.data;
  const text = `${whisper.title ?? ""} ${whisper.description ?? ""}`
    .toLowerCase();
  const hasToken = (token: string) =>
    new RegExp(`(^|[^a-z])${token}([^a-z]|$)`).test(text);

  let crisis: "elevated" | "high" | null = null;
  if (HARD_BLOCK.some((k) => text.includes(k)) || hasToken("kms")) {
    crisis = "high";
  } else if (SOFT_FLAG.some((k) => text.includes(k))) crisis = "elevated";

  if (crisis) {
    const update = await supabase
      .from("whispers")
      .update({ crisis_level: crisis })
      .eq("whisper_id", whisperId);
    if (update.error) return json({ error: "update_failed" }, 500);
  }

  return json({ ok: true, crisis_level: crisis });
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
