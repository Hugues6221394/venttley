"use client";

import type { ReactNode } from "react";

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
  /** When set, each row becomes an <a> for keyboard/screen-reader nav. */
  onRowHref?: (row: T) => string;
}) {
  return (
    <div className="surface overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="bg-canvas/70">
            <tr>
              {columns.map((c) => (
                <th
                  key={c.key}
                  className={`t-th ${c.align === "right" ? "text-right" : ""}`}
                  style={c.width ? { width: c.width } : undefined}
                >
                  {c.header}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr>
                <td
                  colSpan={columns.length}
                  className="text-center py-12 text-ink-muted italic"
                >
                  {empty}
                </td>
              </tr>
            )}
            {rows.map((row) => {
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
                      window.location.assign(onRowHref(row));
                    }}
                  >
                    {cells}
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
