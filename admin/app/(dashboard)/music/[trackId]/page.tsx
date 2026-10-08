import Link from "next/link";
import { notFound } from "next/navigation";
import { randomUUID } from "node:crypto";
import { getOperationalRole } from "@/lib/governance";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card, Row as KV } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { ErrorPanel } from "@/components/ui/empty-state";
import { WorkflowForm } from "@/components/workflows/workflow-form";
import { setMusicTrack } from "@/lib/content-actions";
import { ExternalLink } from "@/components/ui/icons";

export const dynamic = "force-dynamic";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type Track = {
  track_id: string; provider: string; provider_track_id: string; title: string; artist: string; album: string | null; preview_url: string | null;
  duration_ms: number; genre: string | null; mood_tags: string[]; license_code: string; license_url: string | null; rights_holder: string;
  rights_expires_at: string | null; allowed_regions: string[] | null; attribution_text: string | null; is_active: boolean; cache_allowed: boolean;
  created_at: string; updated_at: string;
};
type AuditRow = { audit_id: string; actor_pseudonym: string; action: string; reason: string | null; created_at: string };

export default async function MusicTrackPage({ params }: { params: Promise<{ trackId: string }> }) {
  const role = await getOperationalRole() ?? "";
  if (!["super_admin", "admin", "moderator"].includes(role)) notFound();
  const canManage = role === "super_admin" || role === "admin";
  const { trackId } = await params;
  if (!UUID.test(trackId)) notFound();
  const db = await createAdminClient();
  const [trackResult, posts, whispers, auditResult] = await Promise.all([
    db.from("music_tracks").select("track_id, provider, provider_track_id, title, artist, album, preview_url, duration_ms, genre, mood_tags, license_code, license_url, rights_holder, rights_expires_at, allowed_regions, attribution_text, is_active, cache_allowed, created_at, updated_at").eq("track_id", trackId).maybeSingle(),
    db.from("posts").select("post_id", { count: "exact", head: true }).eq("music_track_id", trackId).is("deleted_at", null),
    db.from("whispers").select("whisper_id", { count: "exact", head: true }).eq("music_track_id", trackId).is("deleted_at", null),
    db.from("audit_log").select("audit_id, actor_pseudonym, action, reason, created_at").eq("target_id", trackId).order("created_at", { ascending: false }).limit(30),
  ]);
  if (trackResult.error) return <ErrorPanel title="Track unavailable" detail="The catalog could not be loaded. Refresh to retry." />;
  if (!trackResult.data) notFound();
  const track = trackResult.data as Track;
  const audit = (auditResult.data ?? []) as AuditRow[];
  const expired = track.rights_expires_at ? new Date(track.rights_expires_at) <= new Date() : false;
  const audible = track.is_active && !expired;
  const usage = posts.error || whispers.error ? null : (posts.count ?? 0) + (whispers.count ?? 0);
  const expiresOn = track.rights_expires_at ? track.rights_expires_at.slice(0, 10) : "";

  return (
    <div className="flex max-w-[1100px] flex-col gap-6">
      <PageHeader eyebrow="Music catalog" title={track.title} subtitle={`${track.artist}${track.album ? ` · ${track.album}` : ""}`}
        actions={<div className="flex gap-2">{track.preview_url && <a href={track.preview_url} target="_blank" rel="noreferrer" className="btn-secondary">Preview <ExternalLink size={12} /></a>}<Link href="/music" className="btn-secondary">Catalog</Link></div>} />
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Card><p className="h-eyebrow">Members hear it</p><div className="mt-2"><Badge tone={audible ? "ok" : "danger"}>{audible ? "yes" : !track.is_active ? "taken down" : "rights expired"}</Badge></div></Card>
        <Card><p className="h-eyebrow">Attached to live Vents and Whispers</p><p className="mt-1 text-3xl font-extrabold text-burgundy">{usage === null ? "—" : usage.toLocaleString()}</p></Card>
        <Card><p className="h-eyebrow">Rights end</p><p className="mt-1 text-lg font-bold text-burgundy">{track.rights_expires_at ? new Date(track.rights_expires_at).toLocaleDateString() : "No end date"}</p></Card>
      </div>
      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card title="Rights record" padded>
          <KV label="Provider" value={`${track.provider} · ${track.provider_track_id}`} />
          <KV label="License" value={track.license_code} />
          <KV label="Rights holder" value={track.rights_holder} />
          {track.license_url && <KV label="License terms" value={<a href={track.license_url} target="_blank" rel="noreferrer" className="text-berry hover:underline">Open</a>} />}
          {track.attribution_text && <KV label="Attribution" value={track.attribution_text} />}
          <KV label="Regions" value={track.allowed_regions?.length ? track.allowed_regions.join(", ") : "Global / unspecified"} />
          <KV label="Caching" value={track.cache_allowed ? "allowed" : "stream only"} />
          <KV label="Length" value={`${Math.round(track.duration_ms / 1000)}s`} />
          {track.genre && <KV label="Genre" value={track.genre} />}
          {track.mood_tags.length > 0 && <KV label="Moods" value={track.mood_tags.join(", ")} />}
          <KV label="Updated" value={new Date(track.updated_at).toLocaleString()} />
        </Card>
        {canManage ? <Card title={track.is_active ? "Take down or change rights" : "Put back"} hint="Needs a reason, MFA, and is audited" padded>
          <div className="flex flex-col gap-4">
            <WorkflowForm action={setMusicTrack} blockUncertainRetry label={track.is_active ? "Take track down" : "Put track back"}
              confirmation={track.is_active
                ? `Silences this track everywhere at once${usage ? `, including on ${usage.toLocaleString()} live Vents and Whispers` : ""}. Nothing is deleted; putting it back restores every attachment.`
                : "Members can pick and hear this track again, including where it was already attached."}>
              <input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="track_id" value={track.track_id} />
              <input type="hidden" name="active" value={track.is_active ? "false" : "true"} />
              <label className="contact-field"><span>Rights end (UTC date, optional)</span><input type="date" name="rights_expires_on" className="input" defaultValue={track.is_active || !expired ? expiresOn : ""} /></label>
              <label className="contact-field"><span>Reason</span><input name="reason" className="input" required minLength={3} maxLength={500} placeholder={track.is_active ? "e.g. rights holder claim" : "e.g. claim withdrawn"} /></label>
            </WorkflowForm>
            {track.is_active && <WorkflowForm action={setMusicTrack} blockUncertainRetry label="Change rights end" confirmation="Members stop hearing the track at the end of that day, UTC. Clear the date for rights with no end.">
              <input type="hidden" name="operation_id" value={randomUUID()} /><input type="hidden" name="track_id" value={track.track_id} />
              <input type="hidden" name="active" value="true" />
              <label className="contact-field"><span>Rights end (UTC date)</span><input type="date" name="rights_expires_on" className="input" defaultValue={expiresOn} /></label>
              <label className="contact-field"><span>Reason</span><input name="reason" className="input" required minLength={3} maxLength={500} placeholder="e.g. license renewed to 2027" /></label>
            </WorkflowForm>}
          </div>
        </Card> : <Card title="Changes" padded><p className="text-sm text-ink-muted">Only admins can take tracks down or change their rights.</p></Card>}
      </div>
      <Card title="History" hint="Latest 30 audited changes to this track" padded={false}>
        {auditResult.error ? <p className="px-5 py-8 text-center text-sm italic text-ink-muted">History could not be loaded.</p>
          : audit.length === 0 ? <p className="px-5 py-8 text-center text-sm italic text-ink-muted">No staff change recorded yet.</p>
          : <ul className="divide-y divide-line">{audit.map((a) => <li key={a.audit_id} className="px-5 py-3"><div className="flex flex-wrap items-center gap-2"><Badge>{a.action.replace("music.", "").replaceAll("_", " ")}</Badge><span className="text-xs text-ink-muted">@{a.actor_pseudonym}</span><time className="ml-auto text-[11px] text-ink-muted">{new Date(a.created_at).toLocaleString()}</time></div>{a.reason && <p className="mt-1 text-xs text-ink-muted">{a.reason}</p>}</li>)}</ul>}
      </Card>
    </div>
  );
}
