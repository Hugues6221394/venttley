// storage-cleanup
//
// Scheduled, bounded deletion worker for orphaned author-owned objects.
//
// Postgres finds candidates directly in storage.objects so nested user-id
// folders and global age ordering work at scale. It binds every bucket to the
// canonical referencing table. Dry-run is the default; deletion also requires
// STORAGE_CLEANUP_ENABLED and an explicit dryRun=false request.
//
// Run via: supabase functions deploy storage-cleanup
// Schedule: cron — `0 4 * * *` (daily 4am UTC).
//
// Env: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY

import { adminClient } from "../_shared/supabase.ts";
import {
  rolloutEnabled,
  verifyInternalSecret,
} from "../_shared/internal_auth.ts";

interface CleanupCandidate {
  bucket_id: string;
  object_name: string;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const auth = verifyInternalSecret(req, {
    envName: "CRON_SECRET",
    headerName: "x-cron-secret",
  });
  if (!auth.ok) return json({ error: auth.error }, auth.status);
  if (!rolloutEnabled("STORAGE_CLEANUP_ENABLED")) {
    return json({ ok: false, disabled: true }, 503);
  }
  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  // Dry-run is deliberately the default. Deletion requires both the rollout
  // switch above and an explicit per-invocation opt-in.
  const dryRun = body?.dryRun !== false;
  const maxDeletes = clamp(
    typeof body?.maxDeletes === "number" ? body.maxDeletes : 250,
    1,
    500,
  );
  try {
    const supabase = adminClient();
    const lookup = await supabase.rpc("list_storage_cleanup_candidates", {
      p_limit: maxDeletes,
    });
    if (lookup.error) return json({ error: "candidate_lookup_failed" }, 500);
    const candidates = (lookup.data ?? []) as CleanupCandidate[];
    const summary = countByBucket(candidates);
    if (dryRun || candidates.length === 0) {
      return json({ ok: true, dry_run: dryRun, candidates: summary });
    }

    const grouped = new Map<string, string[]>();
    for (const candidate of candidates) {
      if (!grouped.has(candidate.bucket_id)) {
        grouped.set(candidate.bucket_id, []);
      }
      grouped.get(candidate.bucket_id)!.push(candidate.object_name);
    }
    let removed = 0;
    for (const [bucket, paths] of grouped) {
      const result = await supabase.storage.from(bucket).remove(paths);
      if (result.error) {
        console.error("storage cleanup removal failed", bucket);
        return json({ error: "removal_failed", removed }, 500);
      }
      removed += paths.length;
    }
    return json({ ok: true, dry_run: false, candidates: summary, removed });
  } catch {
    return json({ error: "cleanup_failed" }, 500);
  }
});

function countByBucket(candidates: CleanupCandidate[]): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const candidate of candidates) {
    counts[candidate.bucket_id] = (counts[candidate.bucket_id] ?? 0) + 1;
  }
  return counts;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(Math.trunc(value), minimum), maximum);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
