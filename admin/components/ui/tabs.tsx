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
    <nav className="tabs">
      {tabs.map((t) => {
        const on = t.key === active;
        const tone = t.tone ?? "neutral";
        const badgeCls =
          tone === "danger"
            ? "bg-danger/10 text-danger"
            : tone === "warn"
              ? "bg-warn/10 text-warn"
              : tone === "ok"
                ? "bg-ok/10 text-ok"
                : "bg-canvas text-ink-muted";
        return (
          <Link
            key={t.key}
            href={buildHref(t.key)}
            aria-current={on ? "page" : undefined}
            className="tab"
          >
            <span>{t.label}</span>
            {t.count !== undefined && (
              <span className={`pill ${badgeCls}`}>{t.count}</span>
            )}
          </Link>
        );
      })}
    </nav>
  );
}
