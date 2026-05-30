import Link from "next/link";

export type Tab = {
  key: string;
  label: string;
  count?: number;
  tone?: "danger" | "warn" | "ok" | "neutral";
};

export function Tabs({
  tabs,
  active,
  basePath,
  paramKey = "tab",
  extraParams,
}: {
  tabs: Tab[];
  active: string;
  basePath: string;
  paramKey?: string;
  /** Preserve other querystring params when switching tabs. */
  extraParams?: Record<string, string | undefined>;
}) {
  const buildHref = (key: string) => {
    const sp = new URLSearchParams();
    if (extraParams) {
      for (const [k, v] of Object.entries(extraParams)) {
        if (v && k !== paramKey) sp.set(k, v);
      }
    }
    sp.set(paramKey, key);
    return `${basePath}?${sp.toString()}`;
  };

  return (
    <nav className="flex items-center gap-1 border-b border-line">
      {tabs.map((t) => {
        const on = t.key === active;
        const tone = t.tone ?? "neutral";
        const badgeCls =
          tone === "danger"
            ? "bg-danger/12 text-danger"
            : tone === "warn"
              ? "bg-warn/15 text-warn"
              : tone === "ok"
                ? "bg-ok/12 text-ok"
                : "bg-line text-ink-muted";
        return (
          <Link
            key={t.key}
            href={buildHref(t.key)}
            className={`relative px-4 py-2.5 text-sm font-semibold transition flex items-center gap-2 ${
              on
                ? "text-burgundy"
                : "text-ink-muted hover:text-burgundy"
            }`}
          >
            <span>{t.label}</span>
            {t.count !== undefined && (
              <span className={`pill ${badgeCls}`}>{t.count}</span>
            )}
            {on && (
              <span className="absolute left-3 right-3 -bottom-px h-0.5 bg-berry rounded-t" />
            )}
          </Link>
        );
      })}
    </nav>
  );
}
