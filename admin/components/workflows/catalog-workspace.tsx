import Link from "next/link";
import { Suspense } from "react";
import { notFound } from "next/navigation";
import { getOperationalRole } from "@/lib/governance";
import { readTribeWorkspace, readMediaWorkspace, readMusicWorkspace } from "@/lib/catalog-workspaces";
import { catalogFilters,catalogHref,CATALOG_PAGE_SIZE,type CatalogKind,type CatalogFilters } from "@/lib/catalog-workspace-model";
import { OperatorPage,OperatorPanel,PanelSkeleton,PanelUnavailable } from "@/components/ui/operator-workspace";
import { Badge } from "@/components/ui/badge";
import { CapabilityNotice,DataWarning } from "@/components/ui/operations";

function Pager({kind,filters,next}:{kind:CatalogKind;filters:CatalogFilters;next?:string}) {
  return <nav aria-label="Queue pagination" className="flex flex-wrap gap-3">
    {filters.after&&<Link className="btn-secondary" href={catalogHref(kind,filters)} prefetch={false}>First page</Link>}
    {next&&<Link className="btn-secondary" href={catalogHref(kind,filters,next)} prefetch={false}>Next page</Link>}
  </nav>;
}
async function TribeQueue({filters}:{filters:CatalogFilters}) {
  const result=await readTribeWorkspace(filters);
  if(result===null)return <PanelUnavailable label="Community queue" retryHref={catalogHref("tribes",filters,filters.after??undefined)}/>;
  const rows=result.slice(0,CATALOG_PAGE_SIZE);
  return <>
    <div className="grid gap-4 sm:grid-cols-3">{[["Communities on this page",rows.length],["Featured on this page",rows.filter(r=>r.is_featured).length],["Inactive on this page",rows.filter(r=>!r.is_active).length]].map(([label,value])=><OperatorPanel key={label} title={String(label)}><p className="text-3xl font-bold tabular-nums">{value}</p></OperatorPanel>)}</div>
    <OperatorPanel title="Communities" hint="Stable reference order, not a popularity ranking. Member counts are stored counters; weekly activity is not inferred from a truncated post sample.">
      {!rows.length?<p>No communities match on this page.</p>:<ul className="divide-y divide-line">{rows.map(row=><li key={row.tribe_id} className="flex flex-wrap items-center justify-between gap-4 py-4">
        <div className="min-w-0"><h2 className="break-words font-bold">{row.name}</h2><p className="text-sm text-ink-muted">{row.category} · {row.member_count.toLocaleString()} members</p><div className="mt-2 flex gap-2"><Badge>{row.is_active?"Active":"Inactive"}</Badge>{row.is_private&&<Badge>Private</Badge>}{row.is_featured&&<Badge tone="info">Featured</Badge>}</div></div>
        <Link href={`/tribes/${row.tribe_id}`} className="btn-secondary" prefetch={false} aria-label={`Open ${row.name}`}>Open community</Link>
      </li>)}</ul>}
    </OperatorPanel>
    <Pager kind="tribes" filters={filters} next={result.length>CATALOG_PAGE_SIZE?rows.at(-1)?.tribe_id:undefined}/>
  </>;
}
async function MediaQueue({filters}:{filters:CatalogFilters}) {
  const result=await readMediaWorkspace(filters);
  if(result===null)return <PanelUnavailable label="Media queue" retryHref={catalogHref("media",filters,filters.after??undefined)}/>;
  const rows=result.slice(0,CATALOG_PAGE_SIZE);
  return <>
    <OperatorPanel title="Media requiring review" hint={`${rows.length} records on this page · ${filters.kind} · ${filters.state}. This is not a global backlog count.`}>
      {!rows.length?<p>No matching media on this page.</p>:<ul className="divide-y divide-line">{rows.map((row,index)=><li key={row.id} className="space-y-3 py-4">
        <div className="flex flex-wrap gap-2"><h2 className="font-bold">{filters.kind==="post"?"Vent image":"Whisper image"} · item {index+1}</h2><Badge tone="warn">{row.status}</Badge>{row.deleted_at&&<Badge>Deleted content · do not restore through media review</Badge>}</div>
        <p className="text-xs text-ink-muted">Created {new Date(row.created_at).toISOString().replace("T"," ").replace("Z"," UTC")}</p>
        <details className="workflow-technical"><summary>Technical reference</summary><code>{row.id}</code></details>
        <Link href={`/media/${filters.kind}/${row.id}`} className="btn-secondary" prefetch={false}>Review</Link>
      </li>)}</ul>}
    </OperatorPanel>
    <Pager kind="media" filters={filters} next={result.length>CATALOG_PAGE_SIZE?rows.at(-1)?.id:undefined}/>
    <CapabilityNotice title="Evidence first">This metadata queue never fetches images or confession text. Review evidence in the authorized moderation workflow before changing visibility. Decisions happen on each item's review page, with a reason; approving never restores deleted content.</CapabilityNotice>
  </>;
}
async function MusicQueue({filters}:{filters:CatalogFilters}) {
  const result=await readMusicWorkspace(filters);
  if(result===null)return <PanelUnavailable label="Music catalog" retryHref={catalogHref("music",filters,filters.after??undefined)}/>;
  const rows=result.slice(0,CATALOG_PAGE_SIZE);
  return <>
    <OperatorPanel title="Rights catalog" hint={`${rows.length} tracks on this page. Enabled is a catalog flag, not proof of a valid license or worldwide rights.`}>
      {!rows.length?<p>No matching tracks on this page.</p>:<ul className="divide-y divide-line">{rows.map(track=><li key={track.track_id} className="space-y-3 py-4">
        <div className="flex flex-wrap gap-2"><h2 className="font-bold break-words">{track.title}</h2><Badge>{track.is_active?"Enabled":"Disabled"}</Badge></div>
        <p className="text-sm text-ink-muted">{track.artist} · {track.provider}</p>
        <dl className="grid gap-3 text-sm sm:grid-cols-2"><div><dt className="font-bold">Recorded license</dt><dd>{track.license_code} · {track.rights_holder}</dd></div>
          <div><dt className="font-bold">Rights deadline</dt><dd>{track.rights_expires_at?new Date(track.rights_expires_at).toISOString().replace("T"," ").replace("Z"," UTC"):"No deadline recorded"}</dd></div>
          <div><dt className="font-bold">Regions</dt><dd>{track.allowed_regions?.length?track.allowed_regions.join(", "):"Unspecified · verify the rights record"}</dd></div>
          <div><dt className="font-bold">Caching policy</dt><dd>{track.cache_allowed?"Catalog permits caching":"Stream only"}</dd></div></dl>
        <details className="workflow-technical"><summary>Technical reference</summary><code>{track.track_id}</code></details>
        <Link href={`/music/${track.track_id}`} className="btn-secondary" prefetch={false}>Open track</Link>
      </li>)}</ul>}
    </OperatorPanel>
    <Pager kind="music" filters={filters} next={result.length>CATALOG_PAGE_SIZE?rows.at(-1)?.track_id:undefined}/>
    <CapabilityNotice title="Rights review, not catalog authorization">No audio or artwork is downloaded here. Open a track to take it down or change its rights end, with a reason and MFA. A metadata entry alone does not establish licensed use.</CapabilityNotice>
  </>;
}
export async function CatalogWorkspace({kind,searchParams}:{kind:CatalogKind;searchParams:Promise<Record<string,string|string[]|undefined>>}) {
  const role=await getOperationalRole();
  if(!role||!["super_admin","admin","moderator"].includes(role))notFound();
  const filters=catalogFilters(kind,await searchParams);
  if(!filters)return <div><DataWarning title="Invalid queue filters">Use the supported status and a valid page cursor.</DataWarning><Link className="btn-secondary" href={`/${kind}`}>Reset filters</Link></div>;
  return <OperatorPage title={kind==="tribes"?"Community workspace":kind==="music"?"Music catalog workspace":"Media review workspace"} subtitle="Bounded queues, explicit scope and no inferred healthy state when a source fails." actions={kind!=="music"?<Link className="btn-secondary" href={kind==="tribes"?"/tribe-governance":"/moderation"}>{kind==="tribes"?"Community governance":"Moderation workspace"}</Link>:undefined}>
    <form method="get" className="workflow-filters" aria-label="Filter workspace">
      {kind!=="media"?<label>{kind==="music"?"Title starts with":"Name starts with"}<input className="input" name="q" maxLength={80} defaultValue={filters.q}/></label>:<label>Content type<select name="kind" className="select" defaultValue={filters.kind}><option value="post">Vent images</option><option value="whisper">Whisper images</option></select></label>}
      {kind==="music"&&<label>Provider identifier<input className="input" name="provider" maxLength={60} defaultValue={filters.provider}/></label>}
      <label>Status<select className="select" name="state" defaultValue={filters.state}>{(kind==="tribes"?["all","active","inactive","featured"]:kind==="music"?["all","active","inactive","expired","expiring"]:["pending","sensitive","blocked"]).map(state=><option key={state} value={state}>{kind==="music"&&state==="active"?"enabled":kind==="music"&&state==="inactive"?"disabled":state}</option>)}</select></label>
      <button className="btn-primary" type="submit">Apply filters</button><Link className="btn-secondary" href={`/${kind}`}>Reset</Link>
    </form>
    <p className="text-xs text-ink-muted">Read snapshot generated on navigation · 25 records per page · reference order · no background audio or image loading.</p>
    <Suspense key={JSON.stringify(filters)} fallback={<PanelSkeleton label={kind==="tribes"?"communities":kind==="music"?"music catalog":"media review"}/>}>{kind==="tribes"?<TribeQueue filters={filters}/>:kind==="music"?<MusicQueue filters={filters}/>:<MediaQueue filters={filters}/>}</Suspense>
  </OperatorPage>;
}
