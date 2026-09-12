"use server";

import { revalidatePath } from "next/cache";
import { rpc } from "@/lib/audit";

export type Evidence = {
  incident_id: string;
  kind: string;
  status: string;
  content_ref: string;
  media_url: string | null;
  author_id: string | null;
  author_pseudonym: string | null;
  labels: Record<string, unknown> | null;
  detected_at: string;
};

export type RevealState = {
  evidence?: Evidence;
  error?: string;
};

/**
 * Disclose one incident's evidence.
 *
 * Deliberately a POST with a typed reason rather than the `?reveal=<id>` link
 * the moderation queue uses for private-message bodies. Two reasons, both
 * specific to this material:
 *
 *  - `admin_read_csam_evidence` refuses an empty reason, and a canned string
 *    baked into a link is not a reason — it is the absence of one wearing the
 *    field's clothes. The access review reads this text.
 *  - A GET is replayed by refresh, back, and link-prefetching, so a reveal
 *    link writes access records nobody performed. One submit, one disclosure,
 *    one row.
 *
 * The RPC does the authorising (super_admin, AAL2) and the recording. This
 * only carries the operator's words to it and the result back.
 */
export async function revealEvidence(
  _prev: RevealState,
  formData: FormData
): Promise<RevealState> {
  const incident = String(formData.get("incident_id") ?? "");
  const reason = String(formData.get("reason") ?? "");

  if (!incident) return { error: "No incident was identified." };
  if (reason.trim().length < 10) {
    return {
      error:
        "State why this material needs to be viewed. This is recorded and read during access review.",
    };
  }

  try {
    const evidence = await rpc<Evidence>("admin_read_csam_evidence", {
      p_incident: incident,
      p_reason: reason.trim(),
    });
    // Refresh so the per-incident access count reflects this read. It costs
    // one more csam.queue_read row, which is accurate: the queue was re-read.
    revalidatePath("/csam");
    return { evidence };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    if (message.includes("aal2_required")) {
      return {
        error:
          "This requires a completed MFA step-up. Finish the challenge at /mfa, then try again.",
      };
    }
    if (message.includes("forbidden")) {
      return { error: "Only a super admin may view child-safety evidence." };
    }
    return { error: message };
  }
}
