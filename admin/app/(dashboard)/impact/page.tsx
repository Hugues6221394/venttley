import { ImpactMetricPage } from "@/components/impact-metric-page";
import { Card } from "@/components/ui/section";

export const dynamic = "force-dynamic";

export default async function ImpactOverviewPage({ searchParams }: { searchParams: Promise<{ range?: string }> }) {
  const { range } = await searchParams;
  return (
    <ImpactMetricPage
      active="/impact"
      title="Impact Center"
      subtitle="What Venttly can responsibly evidence about reach, participation, support, safety, retention, and—only when governed—outcomes. Usage is never presented as impact by itself."
      pillars={["reach","engagement","community","experience","wellbeing","safety","retention","impact"]}
      rangeValue={range}
    >
      <Card title="Theory of change" hint="The evidence chain prevents reach from being mislabelled as impact">
        <div className="grid grid-cols-1 gap-3 md:grid-cols-5">
          {[
            ["Inputs", "Safe anonymous infrastructure, moderators, communities"],
            ["Activities", "Express, respond, connect, report, seek resources"],
            ["Outputs", "People reached, Vents, responses, support participation"],
            ["Outcomes", "Feeling heard, connection, safer participation—only when measured"],
            ["Impact", "Long-term benefit requires longitudinal or stronger evidence"],
          ].map(([title, body], index) => (
            <div key={title} className="surface-flat p-4">
              <p className="h-eyebrow">{index + 1}. {title}</p>
              <p className="mt-2 text-sm leading-relaxed text-ink-muted">{body}</p>
            </div>
          ))}
        </div>
      </Card>
    </ImpactMetricPage>
  );
}
