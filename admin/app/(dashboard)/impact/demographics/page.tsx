import { ImpactDimensionTable } from "@/components/impact-dimension-table";
import { ImpactNav, ImpactRangeLinks } from "@/components/impact-nav";
import { PageHeader } from "@/components/ui/page-header";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { getImpactDimensions, impactRange } from "@/lib/impact";

export const dynamic = "force-dynamic";

export default async function ImpactDemographicsPage({ searchParams }: { searchParams: Promise<{ range?: string }> }) {
  const { range: rangeValue } = await searchParams;
  const range = impactRange(rangeValue);
  const result = await getImpactDimensions(range, "age_band");
  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader eyebrow="Impact & Evidence" title="Demographics" subtitle="Purpose-limited age-band aggregates used to validate age rules and equitable reach. Venttly does not collect demographic fields merely to make a dashboard richer." actions={<ImpactRangeLinks active={range.days} path="/impact/demographics" />} />
      <ImpactNav active="/impact/demographics" />
      {result.error && <DataWarning title="Demographic aggregate unavailable">{result.error}</DataWarning>}
      <ImpactDimensionTable rows={result.data} empty="No age-band cohort currently meets the safe reporting threshold for this window." />
      <CapabilityNotice title="Purpose limitation">
        Only coarse age bands derived from the age-rule record are included. Gender, ethnicity, disability, nationality, and other sensitive demographics are not collected by this reporting system. Adding any field requires a documented purpose, legal/privacy review, consent where required, retention limits, and safe cohort rules.
      </CapabilityNotice>
    </div>
  );
}
