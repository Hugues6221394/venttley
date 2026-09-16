import "server-only";

import { createSsrClient } from "@/lib/supabase/server";

export type ImpactMetric = {
  metric_key: string;
  title: string;
  pillar: "reach" | "engagement" | "community" | "experience" | "wellbeing" | "safety" | "retention" | "impact";
  evidence_level: string;
  description: string;
  formula: string;
  source: string;
  owner: string;
  metric_value: number | string | null;
  previous_value: number | string | null;
  percent_change: number | string | null;
  numerator: number | string | null;
  denominator: number | string | null;
  sample_size: number;
  suppressed: boolean;
  quality_status: "healthy" | "warning" | "degraded" | "unavailable";
  status: "active" | "governance_gated" | "retired";
  minimum_cohort: number;
  methodology_version: string;
};

export type ImpactDimension = {
  dimension_value: string;
  metric_value: number | string | null;
  sample_size: number;
  quality_status: string;
};

export type ImpactMethod = Pick<
  ImpactMetric,
  "metric_key" | "title" | "pillar" | "evidence_level" | "description" | "formula" | "source" | "owner" | "status" | "minimum_cohort" | "methodology_version"
> & {
  cadence: string;
  privacy_classification: string;
  retention_days: number;
};

export type DataQualityCheck = {
  as_of_date: string;
  check_key: string;
  status: "healthy" | "warning" | "degraded" | "unavailable";
  observed_value: number | string | null;
  threshold: number | string | null;
  detail: string;
  checked_at: string;
};

export type ImpactReport = {
  report_id: string;
  report_kind: string;
  title: string;
  audience: "internal" | "external";
  window_start: string;
  window_end: string;
  country_source: string;
  country_filter: string | null;
  status: string;
  methodology_version: string;
  minimum_cohort: number;
  generated_at: string;
  published_at: string | null;
  checksum: string | null;
  metric_count: number;
};

export type ImpactReportValue = {
  ordinal: number;
  metric_key: string;
  title: string;
  pillar: string;
  metric_value: number | string | null;
  previous_value: number | string | null;
  percent_change: number | string | null;
  numerator: number | string | null;
  denominator: number | string | null;
  sample_size: number;
  suppressed: boolean;
  quality_status: string;
  definition: string;
  formula: string;
  source: string;
  methodology_version: string;
};

export type ImpactRange = { start: string; end: string; days: number };

export function impactRange(value?: string): ImpactRange {
  const days = value === "90d" ? 90 : value === "365d" ? 365 : 30;
  const end = new Date();
  const start = new Date(end.getTime() - (days - 1) * 86_400_000);
  return {
    days,
    start: start.toISOString().slice(0, 10),
    end: end.toISOString().slice(0, 10),
  };
}

export async function getImpactMetrics(
  range: ImpactRange,
  dimensionType = "overall",
  dimensionValue = "all",
  countrySource = "none",
): Promise<{ data: ImpactMetric[]; error: string | null }> {
  const supabase = await createSsrClient();
  const result = await supabase.rpc("admin_impact_metrics", {
    p_start: range.start,
    p_end: range.end,
    p_dimension_type: dimensionType,
    p_dimension_value: dimensionValue,
    p_country_source: countrySource,
  });
  return result.error
    ? { data: [], error: result.error.message }
    : { data: (result.data as ImpactMetric[] | null) ?? [], error: null };
}

export async function getImpactDimensions(
  range: ImpactRange,
  dimensionType: "country" | "age_band",
  countrySource: "declared_residence" | "technical_signal" = "declared_residence",
): Promise<{ data: ImpactDimension[]; error: string | null }> {
  const supabase = await createSsrClient();
  const result = await supabase.rpc("admin_impact_dimensions", {
    p_start: range.start,
    p_end: range.end,
    p_dimension_type: dimensionType,
    p_country_source: countrySource,
  });
  return result.error
    ? { data: [], error: result.error.message }
    : { data: (result.data as ImpactDimension[] | null) ?? [], error: null };
}

export async function getImpactMethodology() {
  const supabase = await createSsrClient();
  const result = await supabase.rpc("admin_impact_methodology");
  return result.error
    ? { data: [] as ImpactMethod[], error: result.error.message }
    : { data: (result.data as ImpactMethod[] | null) ?? [], error: null };
}

export async function getImpactDataQuality() {
  const supabase = await createSsrClient();
  const result = await supabase.rpc("admin_impact_data_quality");
  return result.error
    ? { data: [] as DataQualityCheck[], error: result.error.message }
    : { data: (result.data as DataQualityCheck[] | null) ?? [], error: null };
}

export async function getImpactReports(limit = 50) {
  const supabase = await createSsrClient();
  const result = await supabase.rpc("admin_impact_reports", { p_limit: limit });
  return result.error
    ? { data: [] as ImpactReport[], error: result.error.message }
    : { data: (result.data as ImpactReport[] | null) ?? [], error: null };
}

export async function getImpactReport(reportId: string) {
  const supabase = await createSsrClient();
  const result = await supabase.rpc("admin_impact_report", { p_report: reportId });
  const rows = (result.data as ImpactReport[] | null) ?? [];
  return result.error
    ? { data: null as ImpactReport | null, error: result.error.message }
    : { data: rows[0] ?? null, error: null };
}

export async function getImpactReportValues(reportId: string) {
  const supabase = await createSsrClient();
  const result = await supabase.rpc("admin_impact_report_values", { p_report: reportId });
  return result.error
    ? { data: [] as ImpactReportValue[], error: result.error.message }
    : { data: (result.data as ImpactReportValue[] | null) ?? [], error: null };
}
