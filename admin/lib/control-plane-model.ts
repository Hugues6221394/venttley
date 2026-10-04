export const CONTROL_ROUTES = {
  campaigns: "/moderation/campaigns",
  support_cases: "/support/cases",
  legal_requests: "/legal-requests",
  crisis_playbooks: "/crisis/playbooks",
  recovery_readiness: "/recovery-readiness",
  moderation_workforce: "/moderation/workforce",
  model_operations: "/model-operations",
  messaging_operations: "/messaging-operations",
  storage_operations: "/storage-operations",
  regional_compliance: "/regional-compliance",
  transparency_reports: "/transparency-reports",
  experiments: "/experiments",
} as const;

export type ControlSection = keyof typeof CONTROL_ROUTES;
export type ControlSnapshot = {
  section: ControlSection;
  generated_at: string;
  privacy: "aggregate_only";
  data: Record<string, string | number | boolean | null>;
};

export function parseControlSnapshot(value: unknown, section: ControlSection): ControlSnapshot | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  if (row.section !== section || row.privacy !== "aggregate_only" ||
      typeof row.generated_at !== "string" || !Number.isFinite(Date.parse(row.generated_at)) ||
      !row.data || typeof row.data !== "object" || Array.isArray(row.data)) return null;
  const entries = Object.entries(row.data);
  if (entries.length > 100 || entries.some(([key, item]) =>
    !/^[a-z][a-z0-9_]{0,79}$/.test(key) ||
    !(item === null || typeof item === "boolean" ||
      (typeof item === "number" && Number.isFinite(item)) ||
      (typeof item === "string" && item.length <= 100)))) return null;
  return { section, generated_at: row.generated_at, privacy: "aggregate_only", data: Object.fromEntries(entries) };
}

// Never render arbitrary backend strings in a KPI, including provider errors.
export function controlMetric(value: unknown, format: "number" | "hours" | "date" = "number"): string | number {
  if (format === "date") {
    if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(value) || !Number.isFinite(Date.parse(value))) return "Unavailable";
    return new Date(value).toISOString().replace("T", " ").replace(".000Z", " UTC").replace(/Z$/, " UTC");
  }
  if (typeof value !== "number" && !(typeof value === "string" && /^\d+(\.\d+)?$/.test(value))) return "Unavailable";
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric < 0 || numeric > Number.MAX_SAFE_INTEGER) return "Unavailable";
  return format === "hours" ? `${numeric.toLocaleString("en-US")}h` : numeric;
}

export function controlCapability(value: unknown): "available" | "gap" | "unknown" {
  return value === true ? "available" : value === false ? "gap" : "unknown";
}
