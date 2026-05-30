import { headers } from "next/headers";
import { createSsrClient } from "./supabase/server";

/** Best-effort: pull a usable IP from the request headers when behind a proxy. */
async function callerIp(): Promise<string | null> {
  const h = await headers();
  return (
    h.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    h.get("x-real-ip") ??
    null
  );
}

async function callerUserAgent(): Promise<string | null> {
  const h = await headers();
  return h.get("user-agent");
}

/**
 * Write an audit row from a Server Action. Uses the cookie-bound SSR client
 * so auth.uid() inside admin_log() resolves to the acting admin's user_id.
 *
 * The action label should be a dotted noun.verb, e.g. "user.suspend",
 * "post.restore", "broadcast.send", "flag.update", "role.assign".
 */
export async function audit(
  action: string,
  opts?: {
    targetType?: string;
    targetId?: string;
    targetLabel?: string;
    before?: unknown;
    after?: unknown;
    reason?: string;
    metadata?: Record<string, unknown>;
  }
) {
  const supabase = await createSsrClient();
  const ip = await callerIp();
  const ua = await callerUserAgent();
  const meta: Record<string, unknown> = { ...(opts?.metadata ?? {}) };
  if (ip) meta.ip = ip;
  if (ua) meta.user_agent = ua;
  const { error } = await supabase.rpc("admin_log", {
    p_action: action,
    p_target_type: opts?.targetType ?? null,
    p_target_id: opts?.targetId ?? null,
    p_target_label: opts?.targetLabel ?? null,
    p_before: opts?.before ?? null,
    p_after: opts?.after ?? null,
    p_reason: opts?.reason ?? null,
    p_metadata: meta,
  });
  if (error) {
    // Audit failure must not silently swallow — surface in server logs so
    // operators can investigate. Do NOT throw: a failed audit shouldn't
    // block the underlying user-facing action from completing.
    console.error("[audit] failed", { action, error });
  }
}

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
