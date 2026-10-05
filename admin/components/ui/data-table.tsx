"use client";

import type { ReactNode } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";

export type Column<T> = {
  key: string;
  header: string;
  align?: "left" | "right";
  width?: string;
  render: (row: T) => ReactNode;
};

export function DataTable<T>({
  columns,
  rows,
  rowKey,
  empty = "No matches.",
  onRowHref,
}: {
  columns: Column<T>[];
  rows: T[];
  rowKey: (row: T) => string;
  empty?: string;
  /** Adds an explicit, keyboard-accessible detail link to each row. */
  onRowHref?: (row: T) => string;
}) {
  const router = useRouter();
  return (
    <div className="surface overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="bg-canvas">
            <tr>
              {columns.map((c) => (
                <th
                  key={c.key}
                  scope="col"
                  className={`t-th ${c.align === "right" ? "text-right" : ""}`}
                  style={c.width ? { width: c.width } : undefined}
                >
                  {c.header}
                </th>
              ))}
              {onRowHref && <th scope="col" className="t-th"><span className="sr-only">Details</span></th>}
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr>
                <td
                  colSpan={columns.length + (onRowHref ? 1 : 0)}
                  className="text-center py-12 text-sm text-ink-muted"
                >
                  {empty}
                </td>
              </tr>
            )}
            {rows.map((row, rowIndex) => {
              const cells = columns.map((c) => (
                <td
                  key={c.key}
                  className={`t-td ${c.align === "right" ? "text-right" : ""}`}
                >
                  {c.render(row)}
                </td>
              ));
              if (onRowHref) {
                return (
                  <tr
                    key={rowKey(row)}
                    className="t-row cursor-pointer"
                    onClick={(e) => {
                      // Don't intercept clicks on inner buttons/links/forms.
                      if (
                        (e.target as HTMLElement).closest("button,a,form,input,select,textarea,label")
                      )
                        return;
                      router.push(onRowHref(row));
                    }}
                  >
                    {cells}
                    <td className="t-td"><Link prefetch={false} href={onRowHref(row)} className="btn-ghost" aria-label={`Open details for row ${rowIndex + 1}`}>Open</Link></td>
                  </tr>
                );
              }
              return (
                <tr key={rowKey(row)} className="t-row">
                  {cells}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
