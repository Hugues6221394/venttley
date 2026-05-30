import Link from "next/link";
import { ArrowUpRight, ArrowDownRight } from "./icons";

export type Tone = "neutral" | "ok" | "warn" | "danger" | "info" | "crisis";

const toneRing: Record<Tone, string> = {
  neutral: "bg-canvas text-burgundy",
  ok:      "bg-ok/12 text-ok",
  warn:    "bg-warn/15 text-warn",
  danger:  "bg-danger/12 text-danger",
  info:    "bg-info/12 text-info",
  crisis:  "bg-danger text-white",
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
  const body = (
    <div className="stat">
      <div className="flex items-center justify-between gap-2">
        <p className="h-eyebrow">{label}</p>
        {trend !== undefined && trend !== null && (
          <span
            className={`pill ${
              trend > 0
                ? "bg-ok/12 text-ok"
                : trend < 0
                  ? "bg-danger/12 text-danger"
                  : "bg-line text-ink-muted"
            }`}
            title="Compared to previous period"
          >
            {trend > 0 ? (
              <ArrowUpRight size={12} />
            ) : trend < 0 ? (
              <ArrowDownRight size={12} />
            ) : null}
            {Math.abs(trend).toFixed(0)}%
          </span>
        )}
      </div>
      <div className="flex items-baseline gap-2">
        <p className="tabular text-[28px] font-extrabold leading-none text-burgundy">
          {typeof value === "number" ? value.toLocaleString() : value}
        </p>
        {spark && spark.length > 1 && <Sparkline data={spark} tone={tone} />}
      </div>
      {sub && <p className="text-xs text-ink-muted">{sub}</p>}
      {tone !== "neutral" && (
        <span
          className={`mt-1 inline-block self-start h-1 w-8 rounded-full ${toneRing[tone].split(" ")[0]}`}
        />
      )}
    </div>
  );
  return href ? (
    <Link href={href} className="block card-hover">
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
  width = 64,
  height = 22,
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
    tone === "ok" ? "#1F8F4D"
    : tone === "warn" ? "#C77A1A"
    : tone === "danger" || tone === "crisis" ? "#C1303D"
    : tone === "info" ? "#3B6AB6"
    : "#D12E65";
  return (
    <svg width={width} height={height} className="ml-auto opacity-80">
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
