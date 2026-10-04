import Link from "next/link";
import { directoryHref, directoryRoles, directoryStatuses, STAFF_PAGE_SIZE, type DirectoryFilters, type DirectoryPath } from "@/lib/staff-directory-model";

// Reuse current controls and styling; the governance visual redesign is separate.
export function StaffDirectoryFilters({ filters, path }: { filters: DirectoryFilters; path: DirectoryPath }) {
  return <form action={path} method="get" className="flex flex-wrap items-end gap-3 border-b border-line p-5" aria-label="Filter staff directory">
    <label className="text-xs font-bold">Staff role<select name="role" className="select mt-1 block" defaultValue={filters.role}><option value="all">All staff roles</option>{directoryRoles.map(value => <option key={value} value={value}>{value.replaceAll("_", " ")}</option>)}</select></label>
    <label className="text-xs font-bold">Account state<select name="status" className="select mt-1 block" defaultValue={filters.status}>{directoryStatuses.map(value => <option key={value} value={value}>{value === "all" ? "All account states" : value}</option>)}</select></label>
    <button type="submit" className="btn-secondary">Apply filters</button>
    <Link href={path} className="btn-ghost" prefetch={false}>Reset</Link>
  </form>;
}

export function StaffDirectoryPages({ filters, nextId, path }: { filters: DirectoryFilters; nextId?: string; path: DirectoryPath }) {
  return <nav aria-label="Staff directory pages" className="flex flex-wrap items-center justify-between gap-3 border-t border-line p-5">
    <p className="text-xs text-ink-muted">Up to {STAFF_PAGE_SIZE} staff accounts inspected per page. Findings and KPIs are page-scoped. Access may change while browsing; restart after a change.</p>
    <div className="flex gap-3">
      {filters.after && <Link href={directoryHref(filters, undefined, path)} className="btn-secondary" prefetch={false}>First page</Link>}
      {nextId && <Link href={directoryHref(filters, nextId, path)} className="btn-secondary" prefetch={false}>Next page</Link>}
    </div>
  </nav>;
}
