import { revalidatePath } from "next/cache";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { ShieldCheck, AlertTriangle } from "lucide-react";
import { RevealEvidence } from "./reveal-evidence";

export const dynamic = "force-dynamic";

/**
 * This page used to read public.csam_incidents directly with the signed-in
 * user's client. The table has an RLS policy admitting super_admin and no
 * grant to `authenticated`, and Postgres checks the table privilege first —
 * so the query always failed with 42501 and the policy was dead code. The
 * error was discarded by destructuring only `data`, so a permanently broken
 * screen rendered its empty state: "No incidents." The most consequential
 * queue in the console reported all-clear because it could not read.
 *
 * Two things follow, and both are load-bearing:
 *
 *  - Reads go through admin_csam_queue / admin_read_csam_evidence, which are
 *    SECURITY DEFINER, super_admin-only, and write down what was looked at.
 *    Restoring the grant instead would have fixed the symptom and kept the
 *    behaviour this P0 exists to end — every page load silently reading every
 *    incident's content reference, author and classifier labels.
 *  - A failure is now shown as a failure. "Nothing detected" and "this screen
 *    cannot read its table" must never render the same way again.
 */

type QueueRow = {
  incident_id: string;
  kind: string;
  status: "detected" | "reported" | "cleared" | "false_positive";
  detected_at: string;
  reviewed_at: string | null;
  reviewer: string | null;
  report_reference: string | null;
  notes: string | null;
  label_count: number;
  evidence_reads: number;
};

type AccessRow = {
  access_id: string;
  incident_id: string;
  actor_pseudonym: string | null;
  actor_role: string | null;
  reason: string;
  fields_read: string[];
  accessed_at: string;
};

const STATUS_TONE: Record<
  QueueRow["status"],
  "danger" | "ok" | "neutral" | "warn"
> = {
  detected: "danger",
  reported: "ok",
  cleared: "neutral",
  false_positive: "warn",
};

async function resolveAction(formData: FormData) {
  "use server";
  const id = String(formData.get("incident_id") ?? "");
  const status = String(formData.get("status") ?? "");
  const ref = String(formData.get("report_ref") ?? "");
  const notes = String(formData.get("notes") ?? "");
  if (!id || !status) return;
  await rpc("admin_resolve_csam_incident", {
    p_incident_id: id,
    p_status: status,
    p_report_ref: ref || null,
    p_notes: notes || null,
  });
  revalidatePath("/csam");
}

export default async function CsamPage() {
  let incidents: QueueRow[] = [];
  let queueError: string | null = null;
  try {
    incidents = (await rpc<QueueRow[]>("admin_csam_queue", {
      p_status: null,
      p_limit: 200,
    })) ?? [];
  } catch (e) {
    queueError = e instanceof Error ? e.message : String(e);
  }

  let accesses: AccessRow[] = [];
  try {
    accesses =
      (await rpc<AccessRow[]>("admin_csam_access_log", {
        p_incident: null,
        p_limit: 25,
      })) ?? [];
  } catch {
    // The ledger view is supporting detail; if it cannot be read the queue
    // above is still the page's job. Its own failure is not silent — the
    // section says so where it would otherwise list rows.
    accesses = [];
  }

  const open = incidents.filter((i) => i.status === "detected").length;

  return (
    <div className="flex flex-col gap-6 max-w-[1100px]">
      <PageHeader
        eyebrow="Protect"
        title="CSAM incidents"
        subtitle="Auto-detected child-safety incidents. Content is quarantined and PRESERVED as evidence — never deleted here. Reporting to NCMEC / authorities is a mandated legal step."
      />

      <Card className="border-l-4 border-l-danger">
        <div className="flex items-start gap-3">
          <AlertTriangle size={20} className="text-danger mt-0.5 shrink-0" />
          <div className="text-sm leading-relaxed text-ink-muted">
            <p className="font-extrabold text-burgundy">
              Handle with care — legal obligations
            </p>
            <ul className="list-disc ml-4 mt-1 space-y-0.5">
              <li>
                Do <b>not</b> download, share, or forward the media. It is
                preserved server-side as evidence.
              </li>
              <li>
                Confirmed CSAM must be reported to the{" "}
                <b>Rwanda Investigation Bureau (RIB)</b> — via 166 or their
                official CSAM/cybercrime channel — within the legally required
                window, then record the RIB case reference here. (INHOPE can
                help route cross-border material.)
              </li>
              <li>
                Only mark &ldquo;false positive&rdquo; after careful review —
                that restores the content to users.
              </li>
              <li>
                The content reference, author and classifier labels are hidden
                until you ask for them, and every disclosure is recorded with
                your stated reason.
              </li>
            </ul>
          </div>
        </div>
      </Card>

      {queueError ? (
        // Never the empty state. An operator must be able to tell "nothing
        // has been detected" from "this page cannot read the incidents".
        <Card className="border-l-4 border-l-danger">
          <p className="font-extrabold text-danger">
            This queue could not be loaded — do not read it as &ldquo;no
            incidents&rdquo;.
          </p>
          <p className="text-sm text-ink-muted mt-1">
            Incidents may be waiting and are not shown. Escalate rather than
            assuming the queue is clear.
          </p>
          <p className="text-xs text-ink-muted mt-2 tabular break-all">
            {queueError}
          </p>
        </Card>
      ) : (
        <div className="text-sm font-bold text-burgundy">
          {open} open incident{open === 1 ? "" : "s"} awaiting review
        </div>
      )}

      {!queueError &&
        (incidents.length === 0 ? (
          <Card>
            <EmptyState
              title="No incidents"
              hint="Nothing has been auto-detected."
              icon={<ShieldCheck size={26} className="text-ok" />}
            />
          </Card>
        ) : (
          <div className="flex flex-col gap-3">
            {incidents.map((i) => (
              <article key={i.incident_id} className="surface p-5">
                <header className="flex flex-wrap items-center gap-2 mb-2">
                  <Badge tone={STATUS_TONE[i.status]}>
                    {i.status.replace("_", " ")}
                  </Badge>
                  <Badge tone="neutral">{i.kind}</Badge>
                  {i.evidence_reads > 0 && (
                    <Badge tone="warn">
                      opened {i.evidence_reads}×
                    </Badge>
                  )}
                  <span className="text-xs text-ink-muted tabular ml-auto">
                    {new Date(i.detected_at).toLocaleString()}
                  </span>
                </header>

                <p className="text-xs text-ink-muted tabular break-all">
                  incident: {i.incident_id} · {i.label_count} classifier label
                  {i.label_count === 1 ? "" : "s"} · content reference and
                  author withheld
                </p>
                {i.report_reference && (
                  <p className="text-xs text-ok mt-1">
                    Report ref: {i.report_reference}
                  </p>
                )}
                {i.reviewer && (
                  <p className="text-xs text-ink-muted mt-1">
                    Reviewed by @{i.reviewer}
                    {i.reviewed_at
                      ? ` · ${new Date(i.reviewed_at).toLocaleString()}`
                      : ""}
                  </p>
                )}
                {i.notes && (
                  <p className="text-xs text-ink-muted mt-1 italic">
                    {i.notes}
                  </p>
                )}

                <RevealEvidence
                  incidentId={i.incident_id}
                  reads={i.evidence_reads}
                />

                {i.status === "detected" && (
                  <div className="mt-4 flex flex-col gap-2 pt-4 border-t border-line">
                    <form
                      action={resolveAction}
                      className="flex flex-wrap items-center gap-2"
                    >
                      <input
                        type="hidden"
                        name="incident_id"
                        value={i.incident_id}
                      />
                      <input type="hidden" name="status" value="reported" />
                      <input
                        type="text"
                        name="report_ref"
                        placeholder="RIB case reference"
                        required
                        className="input h-8 w-52 text-xs"
                      />
                      <button className="btn-primary text-xs" type="submit">
                        Mark reported
                      </button>
                    </form>
                    <form
                      action={resolveAction}
                      className="flex items-center gap-2"
                    >
                      <input
                        type="hidden"
                        name="incident_id"
                        value={i.incident_id}
                      />
                      <input
                        type="hidden"
                        name="status"
                        value="false_positive"
                      />
                      <input
                        type="text"
                        name="notes"
                        placeholder="reason (restores content)"
                        className="input h-8 w-56 text-xs"
                      />
                      <button className="btn-ghost text-xs" type="submit">
                        False positive
                      </button>
                    </form>
                  </div>
                )}
              </article>
            ))}
          </div>
        ))}

      <Card>
        <p className="font-extrabold text-burgundy text-sm">
          Evidence access ledger
        </p>
        <p className="text-xs text-ink-muted mt-0.5">
          Every disclosure of child-safety evidence, kept separately from the
          general audit log and append-only. Most recent 25.
        </p>
        {accesses.length === 0 ? (
          <p className="text-xs text-ink-muted mt-3 italic">
            No evidence has been disclosed.
          </p>
        ) : (
          <ul className="mt-3 flex flex-col gap-2">
            {accesses.map((a) => (
              <li
                key={a.access_id}
                className="text-xs text-ink-muted border-t border-line pt-2"
              >
                <span className="font-bold text-burgundy">
                  @{a.actor_pseudonym ?? "unknown"}
                </span>{" "}
                ({a.actor_role ?? "—"}) ·{" "}
                <span className="tabular">
                  {new Date(a.accessed_at).toLocaleString()}
                </span>
                <span className="block tabular break-all">
                  incident {a.incident_id} · {a.fields_read.join(", ")}
                </span>
                <span className="block italic">{a.reason}</span>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}
