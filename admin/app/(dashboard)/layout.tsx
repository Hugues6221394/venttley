import { redirect } from "next/navigation";
import Sidebar from "@/components/sidebar";
import Topbar from "@/components/topbar";
import { getRenderStaff } from "@/lib/supabase/server";
import { Suspense } from "react";
import { QueueBadge, type QueueBadgePath } from "@/components/queue-badge";
import OperatorShell from "@/components/operator-shell";
import { hasModernShell } from "@/lib/shell-rollout";

export const dynamic = "force-dynamic";

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const staff = await getRenderStaff();
  if (!staff) redirect("/login");
  const badges = Object.fromEntries((["/moderation", "/appeals", "/safety"] as QueueBadgePath[]).map(path => [
    path, <Suspense key={path} fallback={<span className="text-xs text-ink-muted" aria-label="Loading queue count">…</span>}><QueueBadge path={path} /></Suspense>,
  ]));

  const env = resolveEnv(process.env.NEXT_PUBLIC_SUPABASE_URL);

  if (hasModernShell(staff.role, process.env.ADMIN_SHELL_V2, process.env.ADMIN_SHELL_V2_ROLES)) {
    return <OperatorShell key={`${staff.userId}:${staff.role}`} role={staff.role} pseudonym={staff.pseudonym} env={env} badges={badges}>{children}</OperatorShell>;
  }

  return (
    <div className="min-h-screen flex bg-canvas">
      <Sidebar
        role={staff.role}
        badges={badges}
      />
      <div className="flex flex-col flex-1 min-w-0">
        <Topbar
          pseudonym={staff.pseudonym}
          role={staff.role}
          env={env}
        />
        <main className="flex-1 px-8 py-8 overflow-y-auto">{children}</main>
      </div>
    </div>
  );
}

/**
 * Which system this console is pointed at.
 *
 * Stated, not inferred. This used to look for the substring "staging" in the
 * Supabase URL — but project refs are random (`rbtvilckwihzdpqgjvmz`), so a
 * staging project can never match and every remote deployment showed a green
 * PRODUCTION badge. The badge exists to tell an operator which system they are
 * about to suspend an account on, and it was wrong in exactly the case it
 * exists for.
 *
 * Production remains the fallback when nothing says otherwise, and that
 * asymmetry is deliberate: labelling production as staging invites someone to
 * act carelessly on real members, while labelling staging as production only
 * makes them careful about test data. If the badge must be wrong, it should be
 * wrong in the direction that costs nothing.
 */
function resolveEnv(url?: string): "production" | "staging" | "local" {
  const declared = process.env.NEXT_PUBLIC_ADMIN_ENV;
  if (declared === "staging" || declared === "local") return declared;
  if (declared === "production") return "production";
  if (!url) return "local";
  if (url.includes("localhost") || url.includes("127.0.0.1")) return "local";
  return "production";
}
