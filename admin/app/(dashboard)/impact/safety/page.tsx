import { ImpactMetricPage } from "@/components/impact-metric-page";

export const dynamic = "force-dynamic";

export default async function ImpactSafetyPage({ searchParams }: { searchParams: Promise<{ range?: string }> }) {
  const { range } = await searchParams;
  return <ImpactMetricPage active="/impact/safety" title="Safety" subtitle="Aggregate safety demand and response signals. Crisis classifications are operational signals, never diagnoses." pillars={["safety"]} rangeValue={range} />;
}
