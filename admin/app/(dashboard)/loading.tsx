import { PanelSkeleton } from "@/components/ui/operator-workspace";

// Loading chrome contains no account data and grants no permissions. The
// layout and each data-access boundary still authorize independently.
export default function Loading() {
  return <PanelSkeleton label="operator workspace"/>;
}
