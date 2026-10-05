import type { ReactNode } from "react";

export function PageHeader({
  title,
  subtitle,
  eyebrow,
  actions,
}: {
  title: string;
  subtitle?: string;
  eyebrow?: string;
  actions?: ReactNode;
}) {
  return (
    <header className="page-header">
      <div className="page-header-text">
        {eyebrow && <p className="h-eyebrow">{eyebrow}</p>}
        <h1 className="h-page">{title}</h1>
        {subtitle && <p className="page-header-subtitle">{subtitle}</p>}
      </div>
      {actions && <div className="page-header-actions">{actions}</div>}
    </header>
  );
}

export function SectionHeader({
  title,
  count,
  hint,
  actions,
}: {
  title: string;
  count?: number;
  hint?: string;
  actions?: ReactNode;
}) {
  return (
    <div className="section-row">
      <div className="flex items-center gap-2">
        <h2 className="h-section">{title}</h2>
        {count !== undefined && (
          <span className="pill bg-canvas text-ink-muted">{count}</span>
        )}
        {hint && <span className="text-xs text-ink-muted">· {hint}</span>}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </div>
  );
}
