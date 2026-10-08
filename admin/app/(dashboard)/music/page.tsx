import Link from "next/link";
import { CatalogWorkspace } from "@/components/workflows/catalog-workspace";
import { getOperationalRole } from "@/lib/governance";
import { notFound } from "next/navigation";
import { createAdminClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState, ErrorPanel } from "@/components/ui/empty-state";
import {
  CapabilityNotice,
  Pagination,
  positivePage,
} from "@/components/ui/operations";
import { ExternalLink, Music2, Search } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

const PAGE_SIZE = 50;
const STATES = ["active", "inactive", "expiring", "expired", "all"] as const;

type Track = {
  track_id: string;
  provider: string;
  provider_track_id: string;
  title: string;
  artist: string;
  album: string | null;
  artwork_url: string | null;
  preview_url: string | null;
  duration_ms: number;
  genre: string | null;
  mood_tags: string[];
  license_code: string;
  license_url: string | null;
  rights_holder: string;
  rights_expires_at: string | null;
  allowed_regions: string[] | null;
  attribution_text: string | null;
  is_active: boolean;
  cache_allowed: boolean;
};

function licenseState(track: Track): "active" | "expiring" | "expired" | "inactive" {
  if (!track.is_active) return "inactive";
  if (!track.rights_expires_at) return "active";
  const days = (new Date(track.rights_expires_at).getTime() - Date.now()) / 86_400_000;
  if (days < 0) return "expired";
  if (days <= 30) return "expiring";
  return "active";
}

export default async function MusicPage({
  searchParams,
}: {searchParams:Promise<Record<string,string|string[]|undefined>>}) {
  if(!["super_admin","admin","moderator"].includes(await getOperationalRole()??""))notFound();
  if(process.env.ADMIN_CATALOG_WORKSPACES_UI==="true")return <CatalogWorkspace kind="music" searchParams={searchParams}/>;
  if(Object.values(await searchParams).some(v=>v!==undefined&&typeof v!=="string"))return <ErrorPanel title="Invalid music filters" detail="Use one value per filter."/>;
  return <LegacyMusicPage searchParams={searchParams as Promise<{state?:string;provider?:string;q?:string;page?:string}>}/>;
}

async function LegacyMusicPage({
  searchParams,
}: {
  searchParams: Promise<{
    state?: string;
    provider?: string;
    q?: string;
    page?: string;
  }>;
}) {
  const params = await searchParams;
  const state = (STATES as readonly string[]).includes(params.state ?? "")
    ? (params.state as (typeof STATES)[number])
    : "active";
  const provider = (params.provider ?? "").trim().slice(0, 60);
  const q = (params.q ?? "").trim().slice(0, 100);
  const page = positivePage(params.page);
  const from = (page - 1) * PAGE_SIZE;
  const now = new Date();
  const inThirtyDays = new Date(now.getTime() + 30 * 86_400_000);
  const db = await createAdminClient();

  let query = db
    .from("music_tracks")
    .select(
      "track_id, provider, provider_track_id, title, artist, album, artwork_url, preview_url, duration_ms, genre, mood_tags, license_code, license_url, rights_holder, rights_expires_at, allowed_regions, attribution_text, is_active, cache_allowed",
      { count: "exact" },
    )
    .order("updated_at", { ascending: false });
  if (state === "active") query = query.eq("is_active", true);
  if (state === "inactive") query = query.eq("is_active", false);
  if (state === "expiring") {
    query = query
      .eq("is_active", true)
      .gte("rights_expires_at", now.toISOString())
      .lte("rights_expires_at", inThirtyDays.toISOString());
  }
  if (state === "expired") {
    query = query.not("rights_expires_at", "is", null).lt("rights_expires_at", now.toISOString());
  }
  if (provider) query = query.eq("provider", provider);
  if (q) query = query.ilike("title", `%${q}%`);
  const result = await query.range(from, from + PAGE_SIZE - 1);

  const [activeCount, inactiveCount, expiringCount, providersResult] = await Promise.all([
    db.from("music_tracks").select("track_id", { count: "exact", head: true }).eq("is_active", true),
    db.from("music_tracks").select("track_id", { count: "exact", head: true }).eq("is_active", false),
    db
      .from("music_tracks")
      .select("track_id", { count: "exact", head: true })
      .eq("is_active", true)
      .gte("rights_expires_at", now.toISOString())
      .lte("rights_expires_at", inThirtyDays.toISOString()),
    db.from("music_tracks").select("provider").order("provider").limit(1000),
  ]);

  const errors = [
    result.error,
    activeCount.error,
    inactiveCount.error,
    expiringCount.error,
    providersResult.error,
  ]
    .filter(Boolean)
    .map((entry) => entry!.message);
  const tracks = (result.data ?? []) as Track[];
  const providers = [...new Set((providersResult.data ?? []).map((row) => row.provider))];

  return (
    <div className="flex max-w-[1300px] flex-col gap-6">
      <PageHeader
        eyebrow="Manage"
        title="Music catalog"
        subtitle="Rights-aware metadata for music attached to Vents, Stories, and Whispers. This view never stores or accepts arbitrary commercial audio uploads."
      />

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Card><p className="h-eyebrow">Active tracks</p><p className="mt-1 text-2xl font-extrabold text-burgundy">{activeCount.count ?? "—"}</p></Card>
        <Card><p className="h-eyebrow">Inactive tracks</p><p className="mt-1 text-2xl font-extrabold text-burgundy">{inactiveCount.count ?? "—"}</p></Card>
        <Card><p className="h-eyebrow">Rights expire in 30 days</p><p className="mt-1 text-2xl font-extrabold text-burgundy">{expiringCount.count ?? "—"}</p></Card>
      </div>

      <Card>
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div className="min-w-[230px] flex-1">
            <label className="h-eyebrow mb-1 block">Track title</label>
            <div className="relative">
              <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-ink-muted" />
              <input name="q" defaultValue={q} maxLength={100} className="input pl-9" placeholder="Search catalog" />
            </div>
          </div>
          <div>
            <label className="h-eyebrow mb-1 block">Provider</label>
            <select name="provider" className="select" defaultValue={provider}>
              <option value="">All providers</option>
              {providers.map((name) => <option value={name} key={name}>{name}</option>)}
            </select>
          </div>
          <div>
            <label className="h-eyebrow mb-1 block">Rights state</label>
            <select name="state" className="select" defaultValue={state}>
              {STATES.map((value) => <option value={value} key={value}>{value}</option>)}
            </select>
          </div>
          <button type="submit" className="btn-secondary">Apply</button>
          {(q || provider || state !== "active") && <Link href="/music" className="btn-ghost">Clear</Link>}
        </form>
      </Card>

      {errors.length > 0 && (
        <ErrorPanel
          title="Music catalog data is incomplete"
          detail="One or more catalog sources could not be verified. Missing data is unknown, not zero."
          hint="Track controls stay unavailable while catalog state cannot be proven."
        />
      )}

      {errors.length === 0 && tracks.length === 0 ? (
        <Card>
          <EmptyState icon={<Music2 size={34} />} title="No tracks match this filter." hint="The catalog may be empty, or the provider and rights-state filters may be too narrow." />
        </Card>
      ) : tracks.length > 0 ? (
        <Card title="Catalog" hint={`${(result.count ?? 0).toLocaleString()} matching tracks`} padded={false}>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-canvas/70"><tr><th className="t-th">Track</th><th className="t-th">Provider</th><th className="t-th">License</th><th className="t-th">Regions</th><th className="t-th">Caching</th><th className="t-th">Preview</th></tr></thead>
              <tbody>
                {tracks.map((track) => {
                  const rights = licenseState(track);
                  return (
                    <tr className="t-row" key={track.track_id}>
                      <td className="t-td"><Link href={`/music/${track.track_id}`} className="font-bold text-burgundy hover:text-berry">{track.title}</Link><p className="text-xs text-ink-muted">{track.artist}{track.album ? ` · ${track.album}` : ""}</p><p className="mt-1 font-mono text-[10px] text-ink-muted">{track.track_id}</p></td>
                      <td className="t-td"><Badge tone="info">{track.provider}</Badge><p className="mt-1 font-mono text-[10px] text-ink-muted">{track.provider_track_id}</p></td>
                      <td className="t-td"><Badge tone={rights === "expired" ? "danger" : rights === "expiring" ? "warn" : rights === "inactive" ? "neutral" : "ok"}>{rights}</Badge><p className="mt-1 text-xs text-ink-muted">{track.license_code} · {track.rights_holder}</p>{track.rights_expires_at && <p className="text-[11px] text-ink-muted">expires {new Date(track.rights_expires_at).toLocaleDateString()}</p>}</td>
                      <td className="t-td text-xs text-ink-muted">{track.allowed_regions?.length ? track.allowed_regions.slice(0, 5).join(", ") + (track.allowed_regions.length > 5 ? "…" : "") : "Global / unspecified"}</td>
                      <td className="t-td"><Badge tone={track.cache_allowed ? "ok" : "neutral"}>{track.cache_allowed ? "allowed" : "stream only"}</Badge></td>
                      <td className="t-td">{track.preview_url ? <a href={track.preview_url} target="_blank" rel="noreferrer" className="btn-ghost">Open <ExternalLink size={12} /></a> : <span className="text-xs text-ink-muted">none</span>}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <Pagination basePath="/music" page={page} pageSize={PAGE_SIZE} total={result.count ?? 0} params={{ state, provider, q }} />
        </Card>
      ) : null}

      <CapabilityNotice title="Adding tracks stays with the provider import">
        Open a track to take it down, put it back, or change when its rights end.
        Each change needs a reason and MFA, and is audited. New tracks arrive through
        the provider import, which validates the rights record.
      </CapabilityNotice>
    </div>
  );
}
