import type { ReactNode } from "react";

export function EmptyState({
  title,
  hint,
  icon,
  action,
}: {
  title: string;
  hint?: string;
  icon?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="empty">
      {icon && <div className="text-mauve mb-1">{icon}</div>}
      <p className="text-sm font-semibold text-burgundy">{title}</p>
      {hint && <p className="text-xs text-ink-muted max-w-sm">{hint}</p>}
      {action && <div className="mt-3">{action}</div>}
    </div>
  );
}

export function ErrorPanel({
  title,
  detail,
  hint,
}: {
  title: string;
  detail?: string;
  hint?: string;
}) {
  return (
    <div className="surface p-4 border-danger/30 bg-danger/5">
      <p className="text-sm font-bold text-danger">{title}</p>
      {detail && (
        <pre className="mt-1 text-xs whitespace-pre-wrap text-danger/85 font-mono">
          {detail}
        </pre>
      )}
      {hint && <p className="mt-2 text-xs text-ink-muted">{hint}</p>}
    </div>
  );
}
