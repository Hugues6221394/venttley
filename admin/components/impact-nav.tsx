import Link from "next/link";

const items = [
  ["/impact", "Overview"], ["/impact/reach", "Reach"], ["/impact/geography", "Geography"],
  ["/impact/demographics", "Demographics"], ["/impact/engagement", "Engagement"],
  ["/impact/community-health", "Community health"], ["/impact/wellbeing", "Well-being"],
  ["/impact/program", "Impact program"], ["/impact/safety", "Safety"],
  ["/impact/retention", "Retention"], ["/impact/research", "Research"],
  ["/impact/reports", "Reports"], ["/impact/data-quality", "Data quality"],
  ["/impact/methodology", "Methodology"],
] as const;

export function ImpactNav({ active }: { active: string }) {
  return (
    <nav aria-label="Impact Center" className="surface-flat flex flex-wrap gap-1 p-2">
      {items.map(([href, label]) => (
        <Link
          key={href}
          href={href}
          className={`rounded-lg px-3 py-2 text-xs font-semibold transition-colors ${
            active === href ? "bg-berry text-white" : "text-ink-muted hover:bg-canvas hover:text-burgundy"
          }`}
        >
          {label}
        </Link>
      ))}
    </nav>
  );
}

export function ImpactRangeLinks({ active, path }: { active: number; path: string }) {
  return (
    <div className="flex gap-1 rounded-xl border border-line bg-white p-1">
      {[30, 90, 365].map((days) => (
        <Link
          key={days}
          href={`${path}?range=${days}d`}
          className={`rounded-lg px-3 py-1.5 text-xs font-bold ${active === days ? "bg-burgundy text-white" : "text-ink-muted hover:bg-canvas"}`}
        >
          {days}d
        </Link>
      ))}
    </div>
  );
}
