import { ImpactMetricPage } from "@/components/impact-metric-page";

export const dynamic = "force-dynamic";

export default async function ImpactEngagementPage({ searchParams }: { searchParams: Promise<{ range?: string }> }) {
  const { range } = await searchParams;
  return <ImpactMetricPage active="/impact/engagement" title="Engagement" subtitle="Meaningful platform actions from canonical product tables. Activity indicates use, not well-being or causality." pillars={["engagement"]} rangeValue={range} />;
}
