import "server-only";

import { createSsrClient } from "@/lib/supabase/server";
import { parseControlSnapshot, type ControlSection, type ControlSnapshot } from "./control-plane-model";
export type { ControlSection, ControlSnapshot } from "./control-plane-model";

export async function getControlSnapshot(
  section: ControlSection,
): Promise<{ snapshot: ControlSnapshot | null; error: string | null }> {
  try {
    const supabase = await createSsrClient();
    // Caller-scoped RPC independently checks current staff authority in PostgreSQL.
    const { data, error } = await supabase.rpc("admin_control_plane_snapshot", {
      p_section: section,
    }).abortSignal(AbortSignal.timeout(6000));
    const snapshot = error ? null : parseControlSnapshot(data, section);
    return { snapshot, error: snapshot ? null : "Live aggregates could not be verified." };
  } catch {
    return { snapshot: null, error: "Live aggregates could not be verified." };
  }
}
