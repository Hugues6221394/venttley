import { ImpactNav } from "@/components/impact-nav";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { CapabilityNotice } from "@/components/ui/operations";

export const dynamic = "force-dynamic";

const levels = [
  ["A", "Platform measurement", "Canonical activity and operations", "active"],
  ["B", "Self-report", "Separate opt-in consent and approved instrument", "gated"],
  ["C", "Longitudinal", "Retention, attrition, follow-up, and withdrawal protocol", "gated"],
  ["D", "Comparative", "Pre-registered cohort and confounding plan", "gated"],
  ["E", "Controlled", "Ethics-approved study design and safety monitoring", "gated"],
  ["F", "Independent", "External research team, reproducible methods, and publication", "gated"],
] as const;

export default function ImpactResearchPage() {
  return (
    <div className="flex max-w-[1200px] flex-col gap-6">
      <PageHeader eyebrow="Impact & Evidence" title="Research readiness" subtitle="An evidence ladder that prevents observational product data from being presented as causal or clinical proof." />
      <ImpactNav active="/impact/research" />
      <Card title="Evidence ladder" hint="Claims may not exceed the strongest completed level">
        <div className="flex flex-col gap-3">
          {levels.map(([level,title,requirement,status]) => (
            <div key={level} className="surface-flat flex flex-col gap-2 p-4 sm:flex-row sm:items-center sm:justify-between">
              <div><p className="font-bold text-burgundy">Level {level} · {title}</p><p className="text-sm text-ink-muted">{requirement}</p></div>
              <Badge tone={status === "active" ? "ok" : "warn"}>{status}</Badge>
            </div>
          ))}
        </div>
      </Card>
      <Card title="Do-no-harm review" hint="Required for every research release">
        <ul className="grid list-disc gap-3 pl-5 text-sm text-ink-muted md:grid-cols-2">
          <li>Report negative and null outcomes, not only favourable findings.</li>
          <li>Disclose selection bias, missingness, attrition, and uncertainty.</li>
          <li>Predefine adverse-event response without exposing participants to admins.</li>
          <li>Ensure withdrawal and erasure do not require public identity disclosure.</li>
          <li>Validate translations and cultural interpretation by launch country.</li>
          <li>Prohibit diagnostic, treatment, or causal claims unsupported by the study.</li>
        </ul>
      </Card>
      <CapabilityNotice title="No causal claim from phase-one data">
        Current evidence supports platform measurement only: reached, engaged, responded to, retained, and operationally handled. It does not establish that Venttly improved mental health, prevented harm, or caused any long-term outcome.
      </CapabilityNotice>
    </div>
  );
}
