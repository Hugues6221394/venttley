"use server";

import { redirect } from "next/navigation";
import { activeStaffRole } from "@/lib/staff";
import {
  createRequiredAuthAdminClient,
  createSsrClient,
} from "@/lib/supabase/server";

export async function completeStaffInvite(formData: FormData) {
  const password = String(formData.get("password") ?? "");
  const confirm = String(formData.get("confirm_password") ?? "");
  if (password.length < 14 || password.length > 200 || password !== confirm) {
    redirect("/invite?error=invalid_password");
  }

  const supabase = await createSsrClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/invite?error=invalid_link");
  const role = await activeStaffRole(supabase, user.id);
  if (!role) redirect("/invite?error=not_staff");
  if (user.app_metadata.staff_invite_pending !== true) {
    redirect("/invite?error=invalid_link");
  }

  const { error } = await supabase.auth.updateUser({ password });
  if (error) redirect("/invite?error=update_failed");

  // Clear the server-owned one-time setup state. `app_metadata` cannot be
  // changed by the browser, unlike `user_metadata`, so an established staff
  // session cannot turn /invite into a current-password bypass.
  const authAdmin = createRequiredAuthAdminClient();
  const { error: clearError } = await authAdmin.auth.admin.updateUserById(
    user.id,
    {
      app_metadata: {
        ...user.app_metadata,
        staff_invite_pending: false,
      },
    },
  );
  if (clearError) {
    await supabase.auth.signOut();
    redirect("/invite?error=update_failed");
  }
  redirect("/mfa");
}
