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
      {icon && <div className="empty-icon [&>svg]:h-[18px] [&>svg]:w-[18px]" aria-hidden="true">{icon}</div>}
      <p className="text-sm font-semibold text-burgundy">{title}</p>
      {hint && <p className="text-xs text-ink-muted max-w-sm leading-relaxed">{hint}</p>}
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
    <div data-console-state="unavailable" role="status" className="notice notice-danger flex-col gap-0">
      <p className="text-sm font-semibold text-danger">{title}</p>
      {detail && (
        <pre className="mt-1 text-xs whitespace-pre-wrap text-danger/85 font-mono">
          {detail}
        </pre>
      )}
      {hint && <p className="mt-2 text-xs text-ink-muted">{hint}</p>}
    </div>
  );
}
