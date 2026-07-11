import Link from "next/link";
import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/server";
import { rpc } from "@/lib/audit";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { CheckCircle2, XCircle } from "@/components/ui/icons";

export const dynamic = "force-dynamic";

async function review(formData: FormData) {
  "use server";
  const requestId = String(formData.get("request_id") ?? "");
  const approve = String(formData.get("approve") ?? "") === "true";
  const reason = String(formData.get("reason") ?? "");
  await rpc("admin_review_verification", {
    p_request: requestId,
    p_approve: approve,
    p_reason: reason || null,
  });
  revalidatePath("/verification");
}

type Req = {
  request_id: string;
  user_id: string;
  note: string | null;
  created_at: string;
  users: {
    anonymous_pseudonym: string;
    connections_count: number | null;
    karma_points: number | null;
    is_verified: boolean;
    created_at: string;
  } | null;
};

export default async function VerificationQueuePage() {
  const db = await createAdminClient();
  const { data } = await db
    .from("verification_requests")
    .select(
      "request_id, user_id, note, created_at, users(anonymous_pseudonym, connections_count, karma_points, is_verified, created_at)"
    )
    .eq("status", "pending")
    .order("created_at", { ascending: true })
    .limit(200);

  const rows = (data ?? []) as unknown as Req[];

  return (
    <div className="flex flex-col gap-6 max-w-[1100px]">
      <PageHeader
        eyebrow="Manage"
        title="Verification queue"
        subtitle="Applications for the verified check. Auto-verification is reserved for stunning reach (100K connections / 1M hugs), so most verified members come through here. super_admin only."
      />

      <Card title={`Pending applications · ${rows.length}`} padded={false}>
        {rows.length === 0 ? (
          <div className="px-5 py-12 text-sm text-ink-muted italic">
            No pending verification applications.
          </div>
        ) : (
          <ul className="divide-y divide-line">
            {rows.map((r) => (
              <li key={r.request_id} className="px-5 py-4 flex flex-col gap-3">
                <div className="flex flex-wrap items-center gap-3">
                  <Link
                    href={`/users/${r.user_id}`}
                    className="font-bold text-burgundy hover:text-berry"
                  >
                    @{r.users?.anonymous_pseudonym ?? "—"}
                  </Link>
                  <Badge tone="neutral">
                    {(r.users?.connections_count ?? 0).toLocaleString()} connections
                  </Badge>
                  <Badge tone="neutral">
                    {(r.users?.karma_points ?? 0).toLocaleString()} karma
                  </Badge>
                  {r.users?.created_at && (
                    <span className="text-[11px] text-ink-muted">
                      joined {new Date(r.users.created_at).toLocaleDateString()}
                    </span>
                  )}
                  <span className="text-[11px] text-ink-muted ml-auto">
                    applied {new Date(r.created_at).toLocaleString()}
                  </span>
                </div>

                {r.note && (
                  <p className="text-sm text-burgundy bg-canvas/60 rounded-xl px-4 py-3 italic">
                    “{r.note}”
                  </p>
                )}

                <form action={review} className="flex flex-wrap items-center gap-2">
                  <input type="hidden" name="request_id" value={r.request_id} />
                  <input
                    type="text"
                    name="reason"
                    placeholder="reason (optional)"
                    className="input flex-1 min-w-[200px]"
                  />
                  <button
                    type="submit"
                    name="approve"
                    value="true"
                    className="btn-secondary text-green-700 border-green-300 hover:bg-green-50 inline-flex items-center gap-1"
                  >
                    <CheckCircle2 size={14} /> Approve
                  </button>
                  <button
                    type="submit"
                    name="approve"
                    value="false"
                    className="btn-secondary text-red-600 border-red-300 hover:bg-red-50 inline-flex items-center gap-1"
                  >
                    <XCircle size={14} /> Deny
                  </button>
                </form>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}
