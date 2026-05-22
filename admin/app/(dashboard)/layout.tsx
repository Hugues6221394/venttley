import { redirect } from "next/navigation";
import Sidebar from "@/components/sidebar";
import Topbar from "@/components/topbar";
import { createSsrClient } from "@/lib/supabase/server";

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
  if (row.user_role !== "super_admin") {
    return <NotAuthorized pseudonym={row.anonymous_pseudonym} />;
  }

  return (
    <div className="min-h-screen flex bg-blush">
      <Sidebar />
      <div className="flex flex-col flex-1 min-w-0">
        <Topbar pseudonym={row.anonymous_pseudonym} role={row.user_role} />
        <main className="flex-1 px-6 py-6 overflow-y-auto">
          {children}
        </main>
      </div>
    </div>
  );
}

function NotAuthorized({ pseudonym }: { pseudonym: string }) {
  return (
    <main className="min-h-screen flex items-center justify-center bg-blush px-6">
      <div className="card max-w-md p-8 text-center">
        <p className="text-4xl mb-2">🔒</p>
        <h1 className="text-lg font-extrabold text-burgundy">
          Not authorised
        </h1>
        <p className="text-sm text-burgundy/70 mt-2">
          @{pseudonym} doesn’t have the super_admin role. Ask the platform
          owner to grant it, or sign in with a different account.
        </p>
        <a href="/login" className="btn-secondary mt-6">
          Back to login
        </a>
      </div>
    </main>
  );
}
