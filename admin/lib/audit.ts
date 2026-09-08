import { createSsrClient } from "./supabase/server";

/**
 * NOTE: the `audit()` helper that used to live here has been removed.
 *
 * It called public.admin_log directly, which 20260816092420 revoked from
 * `authenticated` — so every call had been failing, and it logged the error
 * and continued by design, which is why nothing surfaced. By then it also had
 * no callers left: every privileged write goes through an admin_* RPC that
 * writes its audit row in the same transaction as the mutation, which is
 * stronger than a best-effort call afterwards could ever be.
 *
 * If a future action needs to audit something with no natural RPC, add a
 * narrow function like admin_log_login() — fixed action, fixed target, actor
 * from auth.uid() — rather than re-exposing admin_log, which takes an
 * arbitrary action and target and could be used to forge entries.
 */

/**
 * Invoke one of the SECURITY DEFINER admin_* RPCs. Throws if the RPC
 * rejected, so the calling Server Action surfaces a clear error.
 */
export async function rpc<T = unknown>(
  fn: string,
  params: Record<string, unknown>
): Promise<T> {
  const supabase = await createSsrClient();
  const { data, error } = await supabase.rpc(fn, params);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}
