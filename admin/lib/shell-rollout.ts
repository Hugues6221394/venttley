import { isStaffRole } from "./roles";

// Server-only configuration is passed explicitly so this policy is testable.
// This is a presentation rollout, never a replacement for data authorization.
export function hasModernShell(role: string | undefined, enabled?: string, audience?: string): boolean {
  if (enabled !== "true" || !isStaffRole(role)) return false;
  const roles = (audience ?? "super_admin").split(",").map(value => value.trim());
  // Misconfigured cohorts fail closed instead of silently broadening a pilot.
  return roles.length > 0 && roles.every(isStaffRole) && roles.includes(role);
}
