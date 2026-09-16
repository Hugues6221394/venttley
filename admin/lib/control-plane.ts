import "server-only";

import { createSsrClient } from "@/lib/supabase/server";

export type ControlSection =
  | "campaigns"
  | "support_cases"
  | "legal_requests"
  | "crisis_playbooks"
  | "recovery_readiness"
  | "moderation_workforce"
  | "model_operations"
  | "messaging_operations"
  | "storage_operations"
  | "regional_compliance"
  | "transparency_reports"
  | "experiments";

export type ControlSnapshot = {
  section: ControlSection;
  generated_at: string;
  privacy: "aggregate_only";
  data: Record<string, string | number | boolean | null>;
};

export async function getControlSnapshot(
  section: ControlSection,
): Promise<{ snapshot: ControlSnapshot | null; error: string | null }> {
  const supabase = await createSsrClient();
  const { data, error } = await supabase.rpc("admin_control_plane_snapshot", {
    p_section: section,
  });

  if (error) return { snapshot: null, error: error.message };
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return { snapshot: null, error: "The control-plane snapshot returned an invalid shape." };
  }
  return { snapshot: data as ControlSnapshot, error: null };
}
