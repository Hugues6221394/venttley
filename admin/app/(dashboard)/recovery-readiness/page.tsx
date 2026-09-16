import { ControlPlanePage } from "@/components/control-plane-page";
import { controlPages } from "@/lib/control-page-config";

export const dynamic = "force-dynamic";

export default function RecoveryReadinessPage() {
  return <ControlPlanePage config={controlPages.recovery_readiness} />;
}
