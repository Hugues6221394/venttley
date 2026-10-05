import Link from "next/link";
import { ArrowUpRight, ArrowDownRight } from "./icons";

export type Tone = "neutral" | "ok" | "warn" | "danger" | "info" | "crisis";

const toneDot: Record<Tone, string> = {
  neutral: "var(--theme-line-strong)",
  ok:      "rgb(var(--console-ok))",
  warn:    "rgb(var(--console-warn))",
  danger:  "rgb(var(--console-danger))",
  info:    "rgb(var(--console-info))",
  crisis:  "rgb(var(--console-danger))",
};

export function StatCard({
  label,
  value,
  sub,
  tone = "neutral",
  trend,
  href,
  spark,
}: {
  label: string;
  value: string | number;
  sub?: string;
  tone?: Tone;
  /** % change vs comparison period; positive is up. */
  trend?: number | null;
  href?: string;
  /** Tiny inline sparkline values, 6-24 points. */
  spark?: number[];
}) {
  const zero = value === 0 || value === "0";
  const body = (
    <div className={`kpi ${tone === "crisis" ? "is-alert" : ""}`}>
      <div className="flex items-center justify-between gap-2">
        <p className="kpi-label">
          <span className="kpi-tone" style={tone !== "neutral" ? { background: toneDot[tone] } : undefined} aria-hidden="true" />
          {label}
        </p>
        {trend !== undefined && trend !== null && (
          <span
            className={`delta ${trend > 0 ? "delta-up" : trend < 0 ? "delta-down" : "delta-flat"}`}
            title="Compared to previous period"
          >
            {trend > 0 ? (
              <ArrowUpRight size={12} aria-hidden="true" />
            ) : trend < 0 ? (
              <ArrowDownRight size={12} aria-hidden="true" />
            ) : null}
            {Math.abs(trend).toFixed(0)}%
          </span>
        )}
      </div>
      <div className="flex items-end gap-3">
        <p className={`kpi-value ${zero ? "is-zero" : ""}`}>
          {typeof value === "number" ? value.toLocaleString() : value}
        </p>
        {spark && spark.length > 1 && <Sparkline data={spark} tone={tone} />}
      </div>
      {sub && <p className="kpi-sub">{sub}</p>}
    </div>
  );
  return href ? (
    <Link href={href} className="block h-full rounded-xl card-hover">
      {body}
    </Link>
  ) : (
    body
  );
}

/** Inline SVG sparkline — no library. Reads brand color from CSS var. */
export function Sparkline({
  data,
  tone = "neutral",
  width = 72,
  height = 26,
}: {
  data: number[];
  tone?: Tone;
  width?: number;
  height?: number;
}) {
  if (data.length < 2) return null;
  const min = Math.min(...data);
  const max = Math.max(...data);
  const span = max - min || 1;
  const stepX = width / (data.length - 1);
  const points = data
    .map((v, i) => {
      const x = (i * stepX).toFixed(1);
      const y = (height - ((v - min) / span) * height).toFixed(1);
      return `${x},${y}`;
    })
    .join(" ");
  const color =
    tone === "ok" ? "rgb(var(--console-ok,31 143 77))"
    : tone === "warn" ? "rgb(var(--console-warn,199 122 26))"
    : tone === "danger" || tone === "crisis" ? "rgb(var(--console-danger,193 48 61))"
    : tone === "info" ? "rgb(var(--console-info,59 106 182))"
    : "rgb(var(--console-accent,209 46 101))";
  return (
    <svg width={width} height={height} className="ml-auto mb-1 opacity-90" aria-hidden="true">
      <polyline
        fill="none"
        stroke={color}
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
        points={points}
      />
    </svg>
  );
}
