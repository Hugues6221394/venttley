import type { ReactNode } from 'react';
import Link from 'next/link';

// Opt-in primitives: existing workflow pages retain their current interface.
export function OperatorPage({ title, subtitle, actions, children }: { title:string; subtitle:string; actions?:ReactNode; children:ReactNode }) {
  return <div className="operator-page"><header className="operator-page-heading"><p className="h-eyebrow">Control center</p><h1>{title}</h1><p>{subtitle}</p><div className="operator-actions">{actions}</div></header>{children}</div>;
}
export function OperatorPanel({ title, hint, children, className='', actions }: { title:string; hint?:string; children:ReactNode; className?:string; actions?:ReactNode }) {
  return <section className={`operator-panel ${className}`} aria-label={title}><header><div><h2>{title}</h2>{hint && <p>{hint}</p>}</div>{actions}</header>{children}</section>;
}
export function PanelSkeleton({ label, className='' }: { label:string; className?:string }) {
  return <section data-console-loading className={`operator-panel operator-skeleton ${className}`} role="status" aria-label={`Loading ${label}`}><p>Loading {label}…</p><div aria-hidden="true"><i/><i/><i/></div></section>;
}
export function PanelUnavailable({ label, retryHref="/overview" }: { label:string; retryHref?:string }) {
  return <div data-console-state="unavailable" className="operator-unavailable" role="status"><h3>{label} unavailable</h3><p>This source could not be verified. Other panels remain usable; no zero or healthy state is inferred.</p><a href={retryHref} className="btn-secondary">Reload workspace</a></div>;
}
export function OperatorMetric({ label, value, description, comparison }: { label:string; value:number; description:string; comparison?:string }) {
  return <section className="operator-metric" aria-label={label}><h3>{label}</h3><strong>{value.toLocaleString('en-US')}</strong><p>{description}</p>{comparison && <small>{comparison}</small>}</section>;
}
export function OperatorTable({ caption, headings, children }: { caption:string; headings:string[]; children:ReactNode }) {
  return <div className="operator-table-scroll" tabIndex={0} role="region" aria-label={`${caption} table`}><table className="data-table operator-table"><caption className="sr-only">{caption}</caption><thead><tr>{headings.map(label=><th key={label} scope="col">{label}</th>)}</tr></thead><tbody>{children}</tbody></table></div>;
}
export function OperatorFilterBar({ children, label }: { children:ReactNode; label:string }) {
  return <fieldset className="operator-filterbar"><legend className="sr-only">{label}</legend>{children}</fieldset>;
}
