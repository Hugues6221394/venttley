import { revalidatePath } from "next/cache";
import { createSsrClient } from "@/lib/supabase/server";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { ShieldCheck, AlertTriangle } from "lucide-react";

export const dynamic = "force-dynamic";

type Incident = {
  incident_id: string;
  kind: string;
  content_ref: string;
  author_id: string | null;
  labels: Record<string, unknown> | null;
  status: "detected" | "reported" | "cleared" | "false_positive";
  report_reference: string | null;
  detected_at: string;
  reviewed_at: string | null;
  notes: string | null;
};

const STATUS_TONE: Record<Incident["status"], "danger" | "ok" | "neutral" | "warn"> = {
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
  // SSR (logged-in) client: the csam_incidents RLS policy restricts reads to
  // super_admin, so a non-super_admin simply sees nothing.
  const ssr = await createSsrClient();
  const { data } = await ssr
    .from("csam_incidents")
    .select("*")
    .order("detected_at", { ascending: false })
    .limit(200);
  const incidents = (data ?? []) as Incident[];
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
            <p className="font-extrabold text-burgundy">Handle with care — legal obligations</p>
            <ul className="list-disc ml-4 mt-1 space-y-0.5">
              <li>Do <b>not</b> download, share, or forward the media. It is preserved server-side as evidence.</li>
              <li>Confirmed CSAM must be reported to the <b>Rwanda Investigation Bureau (RIB)</b> — via 166 or their official CSAM/cybercrime channel — within the legally required window, then record the RIB case reference here. (INHOPE can help route cross-border material.)</li>
              <li>Only mark &ldquo;false positive&rdquo; after careful review — that restores the content to users.</li>
            </ul>
          </div>
        </div>
      </Card>

      <div className="text-sm font-bold text-burgundy">
        {open} open incident{open === 1 ? "" : "s"} awaiting review
      </div>

      {incidents.length === 0 ? (
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
                <Badge tone={STATUS_TONE[i.status]}>{i.status.replace("_", " ")}</Badge>
                <Badge tone="neutral">{i.kind}</Badge>
                <span className="text-xs text-ink-muted tabular ml-auto">
                  {new Date(i.detected_at).toLocaleString()}
                </span>
              </header>
              <p className="text-xs text-ink-muted tabular break-all">
                content: {i.content_ref} · author: {i.author_id ?? "—"}
              </p>
              {i.report_reference && (
                <p className="text-xs text-ok mt-1">Report ref: {i.report_reference}</p>
              )}
              {i.notes && <p className="text-xs text-ink-muted mt-1 italic">{i.notes}</p>}

              {i.status === "detected" && (
                <div className="mt-4 flex flex-col gap-2 pt-4 border-t border-line">
                  <form action={resolveAction} className="flex flex-wrap items-center gap-2">
                    <input type="hidden" name="incident_id" value={i.incident_id} />
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
                  <form action={resolveAction} className="flex items-center gap-2">
                    <input type="hidden" name="incident_id" value={i.incident_id} />
                    <input type="hidden" name="status" value="false_positive" />
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
      )}
    </div>
  );
}
