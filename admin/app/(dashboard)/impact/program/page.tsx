import { ImpactNav } from "@/components/impact-nav";
import { PageHeader } from "@/components/ui/page-header";
import { Card, Row } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { getImpactMethodology } from "@/lib/impact";

export const dynamic = "force-dynamic";

export default async function ImpactProgramPage() {
  const result = await getImpactMethodology();
  const gated = result.data.filter((metric) => metric.status === "governance_gated");
  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader eyebrow="Impact & Evidence" title="Impact Program" subtitle="Optional research participation is separate from product access, Terms, Privacy acceptance, and the public anonymous persona." />
      <ImpactNav active="/impact/program" />
      {result.error && <DataWarning title="Governance register unavailable">{result.error}</DataWarning>}
      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Card title="Identity separation" hint="Three identities, three purposes">
          <Row label="Product identity" hint="Supabase Auth and authorization; never exposed in reports." value={<Badge tone="ok">separate</Badge>} />
          <Row label="Anonymous social identity" hint="Display name, username, avatar, and persona visible under product rules." value={<Badge tone="ok">separate</Badge>} />
          <Row label="Impact participant identity" hint="Random participant id mapped only in the private schema." value={<Badge tone="ok">private</Badge>} />
        </Card>
        <Card title="Consent architecture" hint="Versioned, purpose-specific, and withdrawable">
          {[
            "Research participation", "Follow-up contact", "Academic sharing", "Human story publication",
          ].map((label) => <Row key={label} label={label} hint="Requires its own consent receipt; never bundled." value={<Badge tone="info">separate</Badge>} />)}
        </Card>
      </div>
      <Card title="Governance-gated outcomes" hint="Definitions exist; collection does not">
        {gated.map((metric) => (
          <Row key={metric.metric_key} label={metric.title} hint={metric.description} value={<Badge tone="warn">not collecting</Badge>} />
        ))}
      </Card>
      <CapabilityNotice title="Phase-one safety gate">
        The database contains program, participant, and append-only consent contracts, but deliberately contains no individual assessment-response table. This makes unreviewed clinical-style data collection technically impossible until a later migration is supported by DPIA, ethics, legal, cultural, licensing, safety-response, retention, and withdrawal decisions.
      </CapabilityNotice>
    </div>
  );
}
