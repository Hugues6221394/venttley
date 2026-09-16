import { ImpactMetricPage } from "@/components/impact-metric-page";

export const dynamic = "force-dynamic";

export default async function ImpactRetentionPage({ searchParams }: { searchParams: Promise<{ range?: string }> }) {
  const { range } = await searchParams;
  return <ImpactMetricPage active="/impact/retention" title="Retention" subtitle="Cohort return behaviour from meaningful activity. Returning can indicate relevance; it does not prove benefit and must be interpreted alongside safety outcomes." pillars={["retention"]} rangeValue={range} />;
}
