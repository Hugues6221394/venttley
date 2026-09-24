"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Compass, ChevronRight, ArrowLeft, ShieldCheck, Users, Lock, LineChart, Keyboard } from "lucide-react";
import { canAccess } from "@/lib/roles";
import { navigationGroups, searchNavigation, visibleNavigation } from "@/lib/navigation";
import { containDialogTab } from "@/lib/dialog-focus";

// A local page directory, never a member/content search endpoint. Neither
// search text nor staff activity is persisted in browser storage or analytics.
export default function PageSearch({ role, onClose }: { role: string; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const results = useRef<HTMLUListElement>(null);
  const router = useRouter();
  const [query, setQuery] = useState("");
  const [group, setGroup] = useState<string | null>(null);
  const pages = query.trim() ? searchNavigation(role, query) : visibleNavigation(role);
  const showGroups = !query.trim() && !group;
  const rows = showGroups ? navigationGroups.map(section => ({
    label: section.label, group: section.label, href: null as string | null,
    pages: pages.filter(page => page.group === section.label),
  })).filter(section => section.pages.length > 0) : pages.filter(page => !group || page.group === group)
    .map(page => ({ ...page, pages: [] }));
  useEffect(() => { dialog.current?.showModal(); input.current?.focus(); }, []);
  function select(row: typeof rows[number]) {
    if (!row.href) { setGroup(row.group); input.current?.focus(); return; }
    // Recheck the prop-derived role immediately before navigating. The server
    // remains authoritative if permissions changed since this render.
    if (canAccess(role, row.href)) { router.push(row.href); onClose(); }
  }
  return <dialog ref={dialog} className="operator-page-search" aria-labelledby="page-search-title"
    onCancel={event => { event.preventDefault(); onClose(); }} onClose={onClose}
    onKeyDown={event => {
      if (event.key === "Tab") { containDialogTab(event); return; }
      if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
      const buttons = Array.from(results.current?.querySelectorAll<HTMLButtonElement>("button") ?? []);
      if (!buttons.length) return;
      event.preventDefault();
      const current = buttons.indexOf(document.activeElement as HTMLButtonElement);
      const next = current < 0 ? (event.key === "ArrowDown" ? 0 : buttons.length - 1) :
        (current + (event.key === "ArrowDown" ? 1 : -1) + buttons.length) % buttons.length;
      buttons[next].focus();
    }}>
    <div className="operator-search-heading">
      <span className="operator-search-symbol"><Compass size={28} /></span>
      <div><h2 id="page-search-title">Page navigation search</h2><p>Jump to a section in this workspace. No member data is searched here.</p></div>
      <button className="icon-btn" type="button" onClick={onClose} aria-label="Close page search">
        <img src="/design/operator-shell/cutout-20-43ca88ea32cb.png" alt="" width={20} height={18} />
      </button>
    </div>
    <div className="operator-search-controls">
      <input ref={input} className="input" aria-label="Find an admin page" placeholder="Type a page name…" value={query}
        maxLength={100} onChange={event => { setQuery(event.target.value); setGroup(null); }}
        onKeyDown={event => { if (event.key === "Enter" && rows[0]) { event.preventDefault(); select(rows[0]); } }} />
      {canAccess(role, "/search") && <Link href="/search" prefetch={false} onClick={onClose} className="operator-audited-search">
        <Users size={18} /><span>Search members<small>Audited search</small></span><ChevronRight size={16} />
      </Link>}
    </div>
    {group && <button className="btn-ghost" type="button" onClick={() => { setGroup(null); input.current?.focus(); }}><ArrowLeft size={16} />All sections</button>}
    <p className="sr-only" role="status">{rows.length} {showGroups ? "sections" : "pages"} available</p>
    <ul ref={results} className="operator-search-results" aria-label={showGroups ? "Sections" : "Matching pages"}>
      {rows.map(row => <li key={row.href ?? row.group}><button type="button" onClick={() => select(row)}>
        <SearchGroupIcon group={row.group} />
        <span className="operator-result-label"><strong>{row.label}</strong>
          {!row.href && <span className="operator-result-count"> · {row.pages.length} pages</span>}
          <small>{row.href ? row.group : row.pages.slice(0, 4).map(page => page.label).join(", ")}</small>
        </span><ChevronRight size={18} />
      </button></li>)}
    </ul>
    {!rows.length && <p className="empty">No matching pages. Try a section or page name.</p>}
    <p className="operator-search-help"><Keyboard size={20} />Use ↑ ↓ to move, Enter to select, and Esc to close.</p>
  </dialog>;
}

function SearchGroupIcon({ group }: { group: string }) {
  const index = navigationGroups.findIndex(section => section.label === group);
  if (index === 0 || index === 3) return <img className="operator-result-icon" alt="" width={44} height={44}
    src={`/design/operator-shell/${index === 0 ? "cutout-27-1c8fd16dd3f1" : "cutout-47-f7ff1061d285"}.png`} />;
  const Icon = [Compass, ShieldCheck, Users, Compass, Lock, LineChart][index] ?? Compass;
  return <span className="operator-result-icon"><Icon size={24} /></span>;
}
