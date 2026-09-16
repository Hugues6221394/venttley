import { ImpactMetricPage } from "@/components/impact-metric-page";
import { DataWarning } from "@/components/ui/operations";

export const dynamic = "force-dynamic";

export default async function WellbeingPage({ searchParams }: { searchParams: Promise<{ range?: string }> }) {
  const { range } = await searchParams;
  return (
    <ImpactMetricPage active="/impact/wellbeing" title="Well-being" subtitle="Governance status for optional, consented self-report measures. Super Admin receives cohort aggregates only and cannot drill into individual scores." pillars={["experience","wellbeing","impact"]} rangeValue={range}>
      <DataWarning title="Clinical-style collection is disabled">
        WHO-5 and individual well-being responses are not collected in phase 1. Activation requires protocol approval, instrument/licensing review, DPIA, ethics and country review, separate consent, withdrawal and erasure handling, adverse-event procedures, and minimum cohorts.
      </DataWarning>
    </ImpactMetricPage>
  );
}
