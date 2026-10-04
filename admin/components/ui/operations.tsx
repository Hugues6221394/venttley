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
    <aside className="surface-flat border border-warn/30 bg-warn/5 px-4 py-3">
      <div className="flex items-start gap-2.5">
        <Lock size={15} className="mt-0.5 shrink-0 text-warn" />
        <div>
          <p className="text-sm font-bold text-burgundy">{title}</p>
          <div className="mt-0.5 text-xs leading-relaxed text-ink-muted">
            {children}
          </div>
        </div>
      </div>
    </aside>
  );
}

export function DataWarning({
  title,
  children,
}: {
  title: string;
  children?: ReactNode;
}) {
  return (
    <aside data-console-state="warning" className="surface-flat border border-danger/25 bg-danger/5 px-4 py-3">
      <div className="flex items-start gap-2.5">
        <AlertTriangle size={15} className="mt-0.5 shrink-0 text-danger" />
        <div>
          <p className="text-sm font-bold text-danger">{title}</p>
          {children && (
            <div className="mt-0.5 text-xs leading-relaxed text-ink-muted">
              {children}
            </div>
          )}
        </div>
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
