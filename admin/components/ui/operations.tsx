import Link from "next/link";
import type { ReactNode } from "react";
import { AlertTriangle, Lock } from "./icons";

export function CapabilityNotice({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <aside className="notice notice-warn">
      <span className="notice-icon" aria-hidden="true"><Lock size={15} /></span>
      <div className="min-w-0">
        <p className="notice-title">{title}</p>
        <div className="notice-body">{children}</div>
      </div>
    </aside>
  );
}

// `caveat` marks a permanent, by-design limitation of the page. Leave it unset
// for anything a failed or unknown source can trigger: route checks treat an
// unmarked warning as degraded.
export function DataWarning({
  title,
  children,
  caveat = false,
}: {
  title: string;
  children?: ReactNode;
  caveat?: boolean;
}) {
  return (
    <aside data-console-state={caveat ? "caveat" : "warning"} className={`notice ${caveat ? "notice-warn" : "notice-danger"}`}>
      <span className="notice-icon" aria-hidden="true"><AlertTriangle size={15} /></span>
      <div className="min-w-0">
        <p className={`notice-title ${caveat ? "" : "text-danger"}`}>{title}</p>
        {children && <div className="notice-body">{children}</div>}
      </div>
    </aside>
  );
}

function hrefWithPage(
  basePath: string,
  params: Record<string, string | undefined>,
  page: number,
): string {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value) query.set(key, value);
  }
  if (page > 1) query.set("page", String(page));
  const encoded = query.toString();
  return encoded ? `${basePath}?${encoded}` : basePath;
}

export function Pagination({
  basePath,
  page,
  pageSize,
  total,
  params = {},
}: {
  basePath: string;
  page: number;
  pageSize: number;
  total: number;
  params?: Record<string, string | undefined>;
}) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  if (pages <= 1) return null;

  return (
    <nav
      aria-label="Pagination"
      className="flex flex-wrap items-center justify-between gap-3 border-t border-line px-5 py-3"
    >
      <p className="text-xs text-ink-muted">
        Page {page} of {pages} · {total.toLocaleString()} total
      </p>
      <div className="flex items-center gap-2">
        {page > 1 ? (
          <Link
            href={hrefWithPage(basePath, params, page - 1)}
            className="btn-ghost"
          >
            Previous
          </Link>
        ) : (
          <span className="btn-ghost pointer-events-none opacity-40">Previous</span>
        )}
        {page < pages ? (
          <Link
            href={hrefWithPage(basePath, params, page + 1)}
            className="btn-ghost"
          >
            Next
          </Link>
        ) : (
          <span className="btn-ghost pointer-events-none opacity-40">Next</span>
        )}
      </div>
    </nav>
  );
}

export function positivePage(value: string | undefined): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : 1;
}
