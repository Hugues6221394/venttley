import Link from "next/link";
import { ImpactDimensionTable } from "@/components/impact-dimension-table";
import { ImpactNav, ImpactRangeLinks } from "@/components/impact-nav";
import { PageHeader } from "@/components/ui/page-header";
import { CapabilityNotice, DataWarning } from "@/components/ui/operations";
import { getImpactDimensions, impactRange } from "@/lib/impact";

export const dynamic = "force-dynamic";

export default async function ImpactGeographyPage({ searchParams }: { searchParams: Promise<{ range?: string; source?: string }> }) {
  const params = await searchParams;
  const range = impactRange(params.range);
  const source = params.source === "technical_signal" ? "technical_signal" : "declared_residence";
  const result = await getImpactDimensions(range, "country", source);
  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader eyebrow="Impact & Evidence" title="Geography" subtitle="Country-level active-person aggregates with source provenance and minimum-cohort suppression. Geography sources are never silently substituted." actions={<ImpactRangeLinks active={range.days} path="/impact/geography" />} />
      <ImpactNav active="/impact/geography" />
      <div className="flex flex-wrap gap-2">
        {(["declared_residence","technical_signal"] as const).map((item) => (
          <Link key={item} href={`/impact/geography?range=${range.days}d&source=${item}`} className={item === source ? "btn-primary" : "btn-secondary"}>
            {item === "declared_residence" ? "Declared home country" : "Coarse technical signal"}
          </Link>
        ))}
      </div>
      {result.error && <DataWarning title="Geography unavailable">{result.error}</DataWarning>}
      <ImpactDimensionTable rows={result.data} empty="No country cohort currently meets the safe reporting threshold for this source and window." />
      <CapabilityNotice title="Country meaning is explicit">
        Declared home country is user-provided profile context. Technical signal is coarse edge-derived country. Neither is silently presented as nationality or current residence, and no city, campus, IP address, or exact location is returned.
      </CapabilityNotice>
    </div>
  );
}
