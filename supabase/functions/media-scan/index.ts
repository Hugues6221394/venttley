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
// Providers: optional self-hosted NudeNet (NSFW_CLASSIFIER_URL) first, then
// Sightengine (SIGHTENGINE_USER / SIGHTENGINE_SECRET). Worst verdict wins.
// CSAM stays on Sightengine only. If neither provider answers, we FAIL SAFE
// and mark the media 'sensitive' (veiled), never 'clean'.
//
// CSAM: Sightengine also offers a separately enabled CSAM model. When enabled,
// a hit is quarantined through record_csam_incident for mandated human review;
// it is never silently downgraded to an ordinary sensitive-media verdict.
//
// Auth: JWT verification ON. The handler also validates the JWT, re-reads the
// row, requires caller ownership, derives the canonical storage URL itself,
// and accepts only a pending item. Caller-supplied URLs are never scanned.

import { adminClient } from "../_shared/supabase.ts";
import { corsHeaders, handleOptions } from "../_shared/cors.ts";
import { rolloutEnabled } from "../_shared/internal_auth.ts";
import { looksLikeSupportedImage } from "./image_magic.ts";
import { isOwnedStoragePath, ownedPathFromPublicUrl } from "./ownership.ts";

type Verdict = "clean" | "sensitive" | "blocked";

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

  let verdict: Verdict = "clean";
  if (sexual >= 0.6 || gore >= 0.7) {
    verdict = "blocked";
  } else if (sexual >= 0.3 || suggestive >= 0.5 || gore >= 0.4) {
    verdict = "sensitive";
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
    (body["minor"] as Record<string, number> | undefined)?.prob,
  ];
  return Math.max(0, ...candidates.map((n) => (typeof n === "number" ? n : 0)));
}

type ScanResult = {
  verdict: Verdict;
  labels: Record<string, unknown>;
  csam: boolean;
};

function worse(a: Verdict, b: Verdict): Verdict {
  const rank: Record<Verdict, number> = {
    clean: 0,
    sensitive: 1,
    blocked: 2,
  };
  return rank[a] >= rank[b] ? a : b;
}

async function scanLocal(bytes: Uint8Array): Promise<ScanResult | null> {
  const base = Deno.env.get("NSFW_CLASSIFIER_URL")?.replace(/\/$/, "");
  if (!base) return null;

  // Free hosting tiers sleep. Render warns that a cold start "can delay
  // requests by 50 seconds or more", and the original 8s budget guaranteed
  // that every first upload after a quiet spell timed out and got quarantined
  // — safe, but it would look like the scanner does not work.
  //
  // Generous because nothing is waiting on this: the client fires media-scan
  // and polls media_status, so a slow scan costs a few more seconds of "being
  // checked", not a blocked screen. Configurable so a paid always-on host can
  // tighten it back down.
  const timeoutMs = Number(Deno.env.get("NSFW_TIMEOUT_MS") ?? "60000");

  try {
    const form = new FormData();
    form.append("file", new Blob([bytes]), "image.bin");
    const res = await fetch(`${base}/classify`, {
      method: "POST",
      body: form,
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!res.ok) return null;
    const body = await res.json();
    const verdict = body.verdict;
    if (verdict !== "clean" && verdict !== "sensitive" && verdict !== "blocked") {
      return null;
    }
    return {
      verdict,
      labels: (body.labels as Record<string, unknown>) ?? {},
      csam: false,
    };
  } catch (_) {
    return null;
  }
}

async function scanSightengine(imageUrl: string): Promise<ScanResult | null> {
  const user = Deno.env.get("SIGHTENGINE_USER");
  const secret = Deno.env.get("SIGHTENGINE_SECRET");
  if (!user || !secret) return null;
  const models = Deno.env.get("SIGHTENGINE_MODELS") ?? "nudity-2.1,gore";
  const api = new URL("https://api.sightengine.com/1.0/check.json");
  api.searchParams.set("url", imageUrl);
  api.searchParams.set("models", models);
  api.searchParams.set("api_user", user);
  api.searchParams.set("api_secret", secret);

  try {
    const res = await fetch(api, { signal: AbortSignal.timeout(6000) });
    const body = await res.json();
    if (body.status !== "success") {
      return {
        verdict: "sensitive",
        labels: { reason: "scan_error" },
        csam: false,
      };
    }
    // CSAM check first — a hit overrides everything and routes to the incident
    // pipeline (quarantine + mandated report), never a normal delete.
    if (Deno.env.get("SIGHTENGINE_CSAM") === "on" && csamProb(body) >= 0.5) {
      return {
        verdict: "blocked",
        labels: { csam: csamProb(body) },
        csam: true,
      };
    }
    const gore = body.gore?.prob ?? body.gore?.classes?.gory ?? 0;
    const { verdict, labels } = classify(body.nudity ?? {}, gore);
    return { verdict, labels, csam: false };
  } catch (_) {
    return {
      verdict: "sensitive",
      labels: { reason: "scan_exception" },
      csam: false,
    };
  }
}

async function scan(
  imageUrl: string,
  bytes: Uint8Array,
): Promise<ScanResult> {
  if (!looksLikeSupportedImage(bytes)) {
    return {
      verdict: "blocked",
      labels: { reason: "invalid_image_magic" },
      csam: false,
    };
  }
  const local = await scanLocal(bytes);
  const remote = await scanSightengine(imageUrl);
  if (remote?.csam) return remote;
  if (!local && !remote) {
    return {
      verdict: "sensitive",
      labels: { reason: "scanner_not_configured" },
      csam: false,
    };
  }
  return {
    verdict: worse(local?.verdict ?? "clean", remote?.verdict ?? "clean"),
    labels: { local: local?.labels, remote: remote?.labels },
    csam: false,
  };
}

async function copyToQuarantine(
  sb: ReturnType<typeof adminClient>,
  sourceBucket: string,
  storedPath: string,
  kind: string,
  id: string,
  bytes: Uint8Array,
): Promise<void> {
  const dest = `${kind}/${id}/${storedPath}`;
  const { error } = await sb.storage.from("media-quarantine").upload(dest, bytes, {
    contentType: "application/octet-stream",
    upsert: true,
  });
  if (error) {
    console.error("quarantine copy failed", sourceBucket);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions()!;
  const headers = { ...corsHeaders, "Content-Type": "application/json" };

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ ok: false, error: "method_not_allowed" }),
      {
        status: 405,
        headers,
      },
    );
  }
  if (!rolloutEnabled("MEDIA_SCAN_ENABLED")) {
    return new Response(
      JSON.stringify({ ok: false, error: "media_scan_disabled" }),
      {
        status: 503,
        headers,
      },
    );
  }

  const authorization = req.headers.get("Authorization");
  const token = authorization?.replace(/^Bearer\s+/i, "").trim();
  if (!token) {
    return new Response(JSON.stringify({ ok: false, error: "unauthorized" }), {
      status: 401,
      headers,
    });
  }

  const sb = adminClient();
  const { data: authData, error: authError } = await sb.auth.getUser(token);
  const callerId = authData.user?.id;
  if (authError || !callerId) {
    return new Response(JSON.stringify({ ok: false, error: "unauthorized" }), {
      status: 401,
      headers,
    });
  }

  let payload: { kind?: string; id?: string };
  try {
    payload = await req.json();
  } catch {
    return new Response(JSON.stringify({ ok: false, error: "bad body" }), {
      status: 400,
      headers,
    });
  }
  const { kind, id } = payload;
  if ((kind !== "post" && kind !== "whisper") || !id) {
    return new Response(
      JSON.stringify({ ok: false, error: "missing fields" }),
      {
        status: 400,
        headers,
      },
    );
  }

  const table = kind === "post" ? "posts" : "whispers";
  const idCol = kind === "post" ? "post_id" : "whisper_id";
  const columns = kind === "post"
    ? "post_id, author_id, image_path, media_status"
    : "whisper_id, author_id, background_image_url, media_status";
  const { data: stored, error: readError } = await sb
    .from(table)
    .select(columns)
    .eq(idCol, id)
    .maybeSingle();
  if (readError) {
    return new Response(
      JSON.stringify({ ok: false, error: "media_lookup_failed" }),
      {
        status: 500,
        headers,
      },
    );
  }
  if (!stored) {
    return new Response(JSON.stringify({ ok: false, error: "not_found" }), {
      status: 404,
      headers,
    });
  }
  const storedRow = stored as Record<string, unknown>;
  if (storedRow.author_id !== callerId) {
    return new Response(JSON.stringify({ ok: false, error: "forbidden" }), {
      status: 403,
      headers,
    });
  }
  if (storedRow.media_status !== "pending") {
    return new Response(
      JSON.stringify({ ok: false, error: "media_not_pending" }),
      {
        status: 409,
        headers,
      },
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const bucket = kind === "post" ? "post-media" : "whispers-media";
  const storedPath = kind === "post"
    ? (typeof storedRow.image_path === "string" &&
        isOwnedStoragePath(storedRow.image_path, callerId)
      ? storedRow.image_path
      : null)
    : (typeof storedRow.background_image_url === "string"
      ? ownedPathFromPublicUrl(
        storedRow.background_image_url,
        supabaseUrl,
        bucket,
        callerId,
      )
      : null);
  if (!storedPath) {
    return new Response(
      JSON.stringify({ ok: false, error: "invalid_media_reference" }),
      {
        status: 409,
        headers,
      },
    );
  }
  const downloaded = await sb.storage.from(bucket).download(storedPath);
  if (downloaded.error || !downloaded.data) {
    return new Response(
      JSON.stringify({ ok: false, error: "media_download_failed" }),
      { status: 500, headers },
    );
  }
  const bytes = new Uint8Array(await downloaded.data.arrayBuffer());
  const imageUrl =
    sb.storage.from(bucket).getPublicUrl(storedPath).data.publicUrl;
  const leaseId = crypto.randomUUID();
  const claim = await sb.rpc("claim_media_scan", {
    p_kind: kind,
    p_content_id: id,
    p_user_id: callerId,
    p_lease_id: leaseId,
  });
  if (claim.error) {
    return new Response(
      JSON.stringify({ ok: false, error: "media_claim_failed" }),
      { status: 500, headers },
    );
  }
  if (claim.data === "rate_limited") {
    return new Response(JSON.stringify({ ok: false, error: "rate_limited" }), {
      status: 429,
      headers,
    });
  }
  if (claim.data !== "claimed") {
    return new Response(
      JSON.stringify({ ok: false, error: "scan_already_claimed" }),
      { status: 409, headers },
    );
  }
  const { verdict, labels, csam } = await scan(imageUrl, bytes);
  if (verdict === "blocked" || verdict === "sensitive") {
    await copyToQuarantine(sb, bucket, storedPath, kind, id, bytes);
  }

  // CSAM hit → route to the incident pipeline: quarantine (preserve, don't
  // delete) + open a super-admin incident for mandated review/reporting.
  if (csam) {
    const incident = await sb.rpc("record_claimed_csam_incident", {
      p_kind: kind,
      p_content_id: id,
      p_user_id: callerId,
      p_lease_id: leaseId,
      p_labels: labels,
    });
    if (incident.error) {
      console.error(
        "CSAM quarantine failed",
        incident.error.code ?? "database_error",
      );
      return new Response(
        JSON.stringify({ ok: false, error: "quarantine_failed" }),
        {
          status: 500,
          headers,
        },
      );
    }
    if (!incident.data) {
      return new Response(
        JSON.stringify({ ok: false, error: "media_state_changed" }),
        { status: 409, headers },
      );
    }
    return new Response(
      JSON.stringify({ ok: true, verdict: "blocked", csam: true }),
      { headers },
    );
  }

  const update = await sb.rpc("complete_media_scan_verdict", {
    p_kind: kind,
    p_content_id: id,
    p_user_id: callerId,
    p_lease_id: leaseId,
    p_verdict: verdict,
    p_labels: labels,
  });

  if (update.error) {
    return new Response(
      JSON.stringify({ ok: false, error: "media_update_failed" }),
      {
        status: 500,
        headers,
      },
    );
  }
  if (update.data !== true) {
    return new Response(
      JSON.stringify({ ok: false, error: "media_state_changed" }),
      {
        status: 409,
        headers,
      },
    );
  }
  return new Response(JSON.stringify({ ok: true, verdict }), { headers });
});
