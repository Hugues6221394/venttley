import { ControlPlanePage } from "@/components/control-plane-page";
import { controlPages } from "@/lib/control-page-config";

export const dynamic = "force-dynamic";

export default function ModerationWorkforcePage() {
  return <ControlPlanePage config={controlPages.moderation_workforce} />;
}
