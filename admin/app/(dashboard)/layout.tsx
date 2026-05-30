import { redirect } from "next/navigation";
import Sidebar from "@/components/sidebar";
import Topbar from "@/components/topbar";
import { createAdminClient, createSsrClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const supabase = await createSsrClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: row, error } = await supabase
    .from("users")
    .select("anonymous_pseudonym, user_role")
    .eq("user_id", user.id)
    .maybeSingle();

  if (error || !row) {
    return <NotAuthorized pseudonym={user.email ?? "unknown"} />;
  }
  if (row.user_role !== "super_admin" && row.user_role !== "admin") {
    return <NotAuthorized pseudonym={row.anonymous_pseudonym} />;
  }

  // Counters used to pin operational urgency in the sidebar / topbar.
  // Service-role client is intentional: the layout already gated the
  // caller's role, and these counts power the chrome on every page.
  const db = await createAdminClient();
  const [{ count: pendingReports }, { count: crisis24h }] = await Promise.all([
    db
      .from("reports")
      .select("report_id", { count: "exact", head: true })
      .eq("is_resolved", false),
    db
      .from("posts")
      .select("post_id", { count: "exact", head: true })
      .not("crisis_level", "is", null)
      .gte(
        "created_at",
        new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
      ),
  ]);

  const env = resolveEnv(process.env.NEXT_PUBLIC_SUPABASE_URL);

  return (
    <div className="min-h-screen flex bg-canvas">
      <Sidebar
        pendingReports={pendingReports ?? 0}
        openIncidents={crisis24h ?? 0}
      />
      <div className="flex flex-col flex-1 min-w-0">
        <Topbar
          pseudonym={row.anonymous_pseudonym}
          role={row.user_role}
          env={env}
          unread={(pendingReports ?? 0) + (crisis24h ?? 0)}
        />
        <main className="flex-1 px-8 py-8 overflow-y-auto">{children}</main>
      </div>
    </div>
  );
}

function resolveEnv(url?: string): "production" | "staging" | "local" {
  if (!url) return "local";
  if (url.includes("localhost") || url.includes("127.0.0.1")) return "local";
  if (url.includes("staging")) return "staging";
  return "production";
}

function NotAuthorized({ pseudonym }: { pseudonym: string }) {
  return (
    <main className="min-h-screen flex items-center justify-center bg-canvas px-6">
      <div className="surface max-w-md p-8 text-center">
        <p className="text-4xl mb-2">🔒</p>
        <h1 className="text-lg font-extrabold text-burgundy">Not authorised</h1>
        <p className="text-sm text-ink-muted mt-2">
          @{pseudonym} doesn&rsquo;t have an admin role. Ask the platform owner
          to grant <code className="font-mono">super_admin</code> or{" "}
          <code className="font-mono">admin</code>, or sign in with a different
          account.
        </p>
        <a href="/login" className="btn-secondary mt-6">
          Back to login
        </a>
      </div>
    </main>
  );
}
