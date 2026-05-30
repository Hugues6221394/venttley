import type { ReactNode } from "react";

export function Card({
  title,
  hint,
  actions,
  children,
  padded = true,
  className = "",
}: {
  title?: string;
  hint?: string;
  actions?: ReactNode;
  children: ReactNode;
  padded?: boolean;
  className?: string;
}) {
  return (
    <section className={`surface ${className}`}>
      {(title || actions) && (
        <header className="flex items-center justify-between gap-2 px-5 pt-4 pb-3 border-b border-line">
          <div>
            {title && <p className="h-section">{title}</p>}
            {hint && <p className="text-xs text-ink-muted mt-0.5">{hint}</p>}
          </div>
          {actions && <div className="flex items-center gap-2">{actions}</div>}
        </header>
      )}
      <div className={padded ? "p-5" : ""}>{children}</div>
    </section>
  );
}

export function Row({
  label,
  value,
  hint,
}: {
  label: string;
  value: ReactNode;
  hint?: string;
}) {
  return (
    <div className="flex items-center justify-between gap-3 py-2 border-b border-line/60 last:border-0">
      <div>
        <p className="text-sm font-semibold text-burgundy">{label}</p>
        {hint && <p className="text-xs text-ink-muted">{hint}</p>}
      </div>
      <div className="text-sm text-burgundy tabular">{value}</div>
    </div>
  );
}
