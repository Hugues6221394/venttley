import { generateImpactReport } from "./actions";
import { ImpactNav } from "@/components/impact-nav";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { getImpactReports } from "@/lib/impact";

export const dynamic = "force-dynamic";

export default async function ImpactReportsPage({ searchParams }: { searchParams: Promise<{ created?: string }> }) {
  const { created } = await searchParams;
  const result=await getImpactReports(50);
  const today=new Date().toISOString().slice(0,10); const start=new Date(Date.now()-29*86_400_000).toISOString().slice(0,10);
  return <div className="flex max-w-[1400px] flex-col gap-6">
    <PageHeader eyebrow="Impact & Evidence" title="Reports" subtitle="AAL2-protected, audited, immutable snapshots. Every export carries its methodology version, reporting window, minimum cohort, and checksum." />
    <ImpactNav active="/impact/reports" />
    {created && <CapabilityNotice title="Report generated">Snapshot {created} was generated. Export links require the stepped-up session to remain active.</CapabilityNotice>}
    {result.error && <DataWarning title="Report register unavailable">{result.error}</DataWarning>}
    <Card title="Generate immutable snapshot" hint="Requires super admin/admin, MFA step-up, and a live aggregate window">
      <form action={generateImpactReport} className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <label className="field-label">Title<input className="input mt-1" name="title" maxLength={160} required defaultValue={`Venttly impact report · ${today}`} /></label>
        <label className="field-label">Report type<select className="input mt-1" name="report_kind" defaultValue="monthly_impact"><option value="monthly_impact">Monthly impact</option><option value="community_health">Community health</option><option value="safety_transparency">Safety transparency</option><option value="country_summary">Country summary</option><option value="research_readiness">Research readiness</option></select></label>
        <label className="field-label">Audience<select className="input mt-1" name="audience" defaultValue="internal"><option value="internal">Internal</option><option value="external">External candidate</option></select></label>
        <label className="field-label">Window start<input className="input mt-1" type="date" name="window_start" defaultValue={start} required /></label>
        <label className="field-label">Window end<input className="input mt-1" type="date" name="window_end" defaultValue={today} required /></label>
        <label className="field-label">Country source<select className="input mt-1" name="country_source" defaultValue="none"><option value="none">Overall</option><option value="declared_residence">Declared home country</option><option value="technical_signal">Coarse technical signal</option></select></label>
        <label className="field-label">Country filter<input className="input mt-1" name="country_filter" maxLength={80} placeholder="Required only for country report" /></label>
        <label className="field-label md:col-span-2">Method note<input className="input mt-1" name="notes" maxLength={1000} placeholder="Optional context; never paste user content" /></label>
        <div className="md:col-span-3"><button className="btn-primary" type="submit">Generate snapshot</button></div>
      </form>
    </Card>
    <Card title="Snapshot register" hint="Latest 50" padded={false}>
      {result.data.length===0 ? <p className="p-5 text-sm text-ink-muted">No report snapshot has been generated.</p> : <div className="overflow-x-auto"><table className="data-table"><thead><tr><th>Report</th><th>Window</th><th>Scope</th><th>Status</th><th>Integrity</th><th>Exports</th></tr></thead><tbody>
        {result.data.map((report)=><tr key={report.report_id}><td><p className="font-semibold text-burgundy">{report.title}</p><p className="font-mono text-[11px] text-ink-muted">{report.report_id}</p></td><td className="whitespace-nowrap text-xs">{report.window_start}<br/>{report.window_end}</td><td><p className="text-xs">{report.report_kind.replaceAll("_"," ")} · {report.audience}</p><p className="text-[11px] text-ink-muted">{report.country_source}{report.country_filter?` · ${report.country_filter}`:""}</p></td><td><Badge tone={report.status==="published"?"ok":"info"}>{report.status}</Badge></td><td><p className="text-xs">{report.metric_count} metrics · n≥{report.minimum_cohort}</p><p className="max-w-40 truncate font-mono text-[10px] text-ink-muted" title={report.checksum??""}>{report.checksum??"No checksum"}</p></td><td><div className="flex flex-wrap gap-1">{["csv","xlsx","pdf","json"].map((format)=><a key={format} className="btn-ghost" href={`/impact/reports/${report.report_id}/export?format=${format}`}>{format.toUpperCase()}</a>)}</div></td></tr>)}
      </tbody></table></div>}
    </Card>
    <CapabilityNotice title="Publication is a separate decision">Generating or exporting a snapshot does not publish it. External release still requires methodology review, privacy review, narrative review, and an approved publication transition. Human stories require separate explicit consent and remain outside this aggregate report.</CapabilityNotice>
  </div>;
}
