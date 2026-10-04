export const INVITATION_PAGE_SIZE = 25;
export type InvitationCursor = { beforeAt: string | null; beforeId: string | null };
export type InvitationItem = {
  invitation_id: string;
  username: string;
  requested_role: string;
  state: "reserved" | "provider_accepted" | "access_assigned";
  created_at: string;
  provider_accepted_at: string | null;
  access_assigned_at: string | null;
  requested_by_name: string;
  current_role: string | null;
  account_status: string | null;
  sign_in_observed: boolean;
  auth_record_missing: boolean;
  version: number;
  grant_expires_at: string;
  cancelled_at: string | null;
  grant_expired: boolean;
  setup_ready: boolean;
};
export type InvitationRegister = { enabled: false } | {
  enabled: true;
  measured_at: string;
  items: InvitationItem[];
};
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function dateValue(value: unknown): value is string {
  return typeof value === "string" && value.length <= 40 && Number.isFinite(Date.parse(value));
}
export function parseInvitationRegister(value: unknown): InvitationRegister | null {
  if (!value || typeof value !== "object") return null;
  const row = value as Record<string, unknown>;
  if (row.enabled === false) return { enabled: false };
  if (row.enabled !== true || !dateValue(row.measured_at) || !Array.isArray(row.items) || row.items.length > 26) return null;
  for (const item of row.items) {
    if (!item || typeof item !== "object"
      || typeof item.invitation_id !== "string" || !uuidPattern.test(item.invitation_id)
      || typeof item.username !== "string" || typeof item.requested_role !== "string"
      || typeof item.requested_by_name !== "string" || !["reserved", "provider_accepted", "access_assigned"].includes(item.state)
      || !dateValue(item.created_at)
      || !(item.provider_accepted_at === null || dateValue(item.provider_accepted_at))
      || !(item.access_assigned_at === null || dateValue(item.access_assigned_at))
      || !(item.current_role === null || typeof item.current_role === "string")
      || !(item.account_status === null || typeof item.account_status === "string")
      || typeof item.sign_in_observed !== "boolean" || typeof item.auth_record_missing !== "boolean") return null;
    if (!Number.isSafeInteger(item.version) || item.version < 1 || !dateValue(item.grant_expires_at)
      || !(item.cancelled_at === null || dateValue(item.cancelled_at))
      || typeof item.grant_expired !== "boolean" || typeof item.setup_ready !== "boolean") return null;
  }
  return value as InvitationRegister;
}
export function invitationCursor(params: Record<string, string | string[] | undefined>): InvitationCursor | null {
  const { beforeAt, beforeId } = params;
  if (beforeAt === undefined && beforeId === undefined) return { beforeAt: null, beforeId: null };
  if (typeof beforeAt !== "string" || typeof beforeId !== "string" || !uuidPattern.test(beforeId)) return null;
  // Preserve PostgreSQL microseconds: Date.toISOString() would lose cursor precision.
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)$/.test(beforeAt) || !Number.isFinite(Date.parse(beforeAt))) return null;
  return { beforeAt, beforeId };
}
export function invitationHref(item: InvitationItem): string {
  return `/staff/invitations?${new URLSearchParams({ beforeAt: item.created_at, beforeId: item.invitation_id })}`;
}
