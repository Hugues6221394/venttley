import { redirect } from "next/navigation";
import { activeStaffRole } from "@/lib/staff";
import { createSsrClient } from "@/lib/supabase/server";
import { Card } from "@/components/ui/section";
import { Badge } from "@/components/ui/badge";
import { Heart, KeyRound } from "@/components/ui/icons";
import { completeStaffInvite } from "./actions";

export const dynamic = "force-dynamic";

const ERROR: Record<string, string> = {
  invalid_link: "This invitation link is invalid. Ask a super admin for a new invitation.",
  expired_link: "This invitation has expired or was already used. Ask a super admin for a new invitation.",
  invalid_password: "Use matching passwords between 14 and 200 characters.",
  not_staff: "This account does not currently have staff access.",
  update_failed: "The password could not be set. Retry once, then ask a super admin to inspect the account.",
};

export default async function InvitePage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  const supabase = await createSsrClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user && !error) redirect("/login");
  const role = user ? await activeStaffRole(supabase, user.id) : null;
  const pendingInvite = user?.app_metadata.staff_invite_pending === true;

  return (
    <main className="min-h-screen bg-canvas px-4 py-12">
      <div className="mx-auto flex max-w-md flex-col gap-6">
        <div className="flex items-center justify-center gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-berry text-white"><Heart size={19} fill="currentColor" /></div>
          <div><p className="font-extrabold text-burgundy">Venttly</p><p className="h-eyebrow">Staff invitation</p></div>
        </div>
        <Card title="Secure your staff account" hint="Set a unique password, then enroll or challenge MFA">
          {error && <div className="mb-4 rounded-xl bg-danger/8 px-3 py-2 text-sm font-semibold text-danger">{ERROR[error] ?? "The invitation could not be completed."}</div>}
          {user && role && pendingInvite ? (
            <form action={completeStaffInvite} className="flex flex-col gap-3">
              <div className="flex items-center gap-2"><Badge tone="info">{role.replaceAll("_", " ")}</Badge><span className="text-xs text-ink-muted">{user.email}</span></div>
              <label className="text-xs font-semibold text-burgundy/80">New password<input name="password" type="password" required minLength={14} maxLength={200} autoComplete="new-password" className="input mt-1 w-full" /></label>
              <label className="text-xs font-semibold text-burgundy/80">Confirm password<input name="confirm_password" type="password" required minLength={14} maxLength={200} autoComplete="new-password" className="input mt-1 w-full" /></label>
              <button type="submit" className="btn-primary mt-2"><KeyRound size={14} /> Set password and continue</button>
              <p className="text-[11px] leading-relaxed text-ink-muted">Use a password manager. The next step requires TOTP MFA before the console becomes accessible.</p>
            </form>
          ) : (
            <p className="text-sm text-ink-muted">Open the newest invitation email. If the link has expired, ask a super admin to inspect the existing account before retrying.</p>
          )}
        </Card>
      </div>
    </main>
  );
}
