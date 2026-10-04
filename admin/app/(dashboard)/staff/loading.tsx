import { PanelSkeleton } from "@/components/ui/operator-workspace";

// No identities or permissions are inferred by the loading state. Each page
// independently authorizes before reading staff data or constructing controls.
export default function Loading() {
  return <PanelSkeleton label="staff workspace" />;
}
