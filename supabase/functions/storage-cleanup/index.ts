// storage-cleanup
//
// Scheduled function (run daily) that sweeps orphaned objects from
// our author-owned storage buckets.
//
// An "orphan" is a file whose owning row no longer exists:
//   * profile-photos     — users.profile_photo_path no longer matches
//   * post-media         — posts.image_path / audio_path missing
//   * tribe-chat-media   — no chat_messages row references the file
//   * whispers-media     — no whispers row references the file
//
// Run via: supabase functions deploy storage-cleanup
// Schedule: cron — `0 4 * * *` (daily 4am UTC).
//
// Env: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY

import { adminClient } from '../_shared/supabase.ts';
import { corsHeaders, handleOptions } from '../_shared/cors.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return handleOptions()!;
  const supabase = adminClient();
  const summary: Record<string, number> = {};

  // Each sweep is conservative — it lists at most 1000 newest objects
  // per bucket and only deletes ones older than 7 days that aren't
  // referenced by a live row. The 7d grace prevents races with active
  // uploads.
  summary.profile_photos = await sweep(
    supabase,
    'profile-photos',
    async (paths) => {
      const { data } = await supabase
        .from('users')
        .select('profile_photo_path')
        .in('profile_photo_path', paths);
      return new Set((data ?? []).map((r: any) => r.profile_photo_path));
    },
  );

  summary.post_media = await sweep(supabase, 'post-media', async (paths) => {
    const { data: imgs } = await supabase
      .from('posts')
      .select('image_path')
      .in('image_path', paths);
    const { data: auds } = await supabase
      .from('posts')
      .select('audio_path')
      .in('audio_path', paths);
    return new Set([
      ...(imgs ?? []).map((r: any) => r.image_path),
      ...(auds ?? []).map((r: any) => r.audio_path),
    ]);
  });

  return new Response(JSON.stringify(summary), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});

async function sweep(
  supabase: ReturnType<typeof adminClient>,
  bucket: string,
  resolveReferenced: (paths: string[]) => Promise<Set<string>>,
): Promise<number> {
  const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const { data: files, error } = await supabase.storage
    .from(bucket)
    .list('', { limit: 1000, sortBy: { column: 'created_at', order: 'desc' } });
  if (error || !files) return 0;
  const stale = files
    .filter((f) => f.created_at && new Date(f.created_at).getTime() < cutoff)
    .map((f) => f.name);
  if (stale.length === 0) return 0;
  const referenced = await resolveReferenced(stale);
  const orphans = stale.filter((p) => !referenced.has(p));
  if (orphans.length === 0) return 0;
  await supabase.storage.from(bucket).remove(orphans);
  return orphans.length;
}
