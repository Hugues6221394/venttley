import { ImpactMetricPage } from "@/components/impact-metric-page";

export const dynamic = "force-dynamic";

export default async function ImpactReachPage({ searchParams }: { searchParams: Promise<{ range?: string }> }) {
  const { range } = await searchParams;
  return <ImpactMetricPage active="/impact/reach" title="Reach" subtitle="People and accounts reached by Venttly. Reach describes scale, not improvement in anyone’s life." pillars={["reach"]} rangeValue={range} />;
}
