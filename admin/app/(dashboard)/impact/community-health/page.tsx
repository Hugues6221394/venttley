import { ImpactMetricPage } from "@/components/impact-metric-page";

export const dynamic = "force-dynamic";

export default async function CommunityHealthPage({ searchParams }: { searchParams: Promise<{ range?: string }> }) {
  const { range } = await searchParams;
  return <ImpactMetricPage active="/impact/community-health" title="Community health" subtitle="Whether expression receives a timely response and whether people participate in supporting others. A response is not automatically classified as positive support." pillars={["community"]} rangeValue={range} />;
}
