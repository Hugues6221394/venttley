export type InboxRolloutHealth = {
  enabled: boolean;
  audience_roles: string[];
  worker_at: string | null;
  worker_stale: boolean;
  pending: number;
};

export const inboxAudiences = {
  super_admin: { label: 'Super admins only', roles: ['super_admin'] },
  leads: { label: 'Super admins and admins', roles: ['super_admin', 'admin'] },
  all: { label: 'All staff roles', roles: ['super_admin', 'admin', 'moderator', 'support', 'analyst', 'read_only_auditor'] },
} as const;

export type InboxAudience = keyof typeof inboxAudiences;

export function audienceFor(roles: readonly string[] | null | undefined): InboxAudience | null {
  if (!roles) return null;
  const key = [...roles].sort().join(',');
  for (const [name, preset] of Object.entries(inboxAudiences)) {
    if ([...preset.roles].sort().join(',') === key) return name as InboxAudience;
  }
  return null;
}
