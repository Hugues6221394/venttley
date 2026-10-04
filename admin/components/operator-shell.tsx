"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import Link, { useLinkStatus } from "next/link";
import { usePathname } from "next/navigation";
import Topbar from "./topbar";
import { LayoutDashboard, ShieldCheck, Database, Lock, LineChart, ChevronDown, Menu, X } from "./ui/icons";
import { Star, Search } from "lucide-react";
import dynamic from "next/dynamic";
import { activeNavigation, navigationGroups, safeFavorites, visibleNavigation } from "@/lib/navigation";
import { containDialogTab } from "@/lib/dialog-focus";
import { useStaffAttention } from "./staff-attention";
import { attentionDestination } from "@/lib/inbox-model";

const groupIcons = [LayoutDashboard, ShieldCheck, null, Database, Lock, LineChart];
const PageSearch = dynamic(() => import("./page-search"), {
  loading: () => <p role="status" className="operator-search-loading">Opening page search…</p>,
});

export default function OperatorShell({ role, pseudonym, env, badges, children }: {
  role: string; pseudonym: string; env: "production" | "staging" | "local";
  badges: Partial<Record<string, ReactNode>>; children: ReactNode;
}) {
  const pathname = usePathname();
  const active = activeNavigation(role, pathname);
  const [favorites, setFavorites] = useState<string[]>([]);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [compact, setCompact] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const searchButton = useRef<HTMLButtonElement>(null);
  const previouslyOpen = useRef({ mobile: false, search: false });
  const mobileButton = useRef<HTMLButtonElement>(null);
  const allowedFavorites = safeFavorites(role, favorites);
  const isFavorite = !!active && allowedFavorites.includes(active.href);
  useEffect(() => { setMobileOpen(false); }, [pathname]);
  useEffect(() => {
    // Restore after React removes the modal. Focusing before that commit is
    // ignored because the browser still treats the trigger as inert.
    if (previouslyOpen.current.mobile && !mobileOpen) mobileButton.current?.focus();
    if (previouslyOpen.current.search && !searchOpen) searchButton.current?.focus();
    previouslyOpen.current = { mobile: mobileOpen, search: searchOpen };
  }, [mobileOpen, searchOpen]);
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k" && !document.querySelector("dialog[open]")) {
        event.preventDefault(); setSearchOpen(true);
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  const nav = (mobile: boolean) => <ShellNavigation role={role} pathname={pathname}
    favorites={allowedFavorites} badges={badges} mobile={mobile}
    onNavigate={() => setMobileOpen(false)} />;

  return <div className="operator-shell-v2" data-density={compact ? "compact" : "comfortable"}>
    <a className="operator-skip" href="#workspace-content">Skip to content</a>
    <aside className="operator-sidebar" aria-label="Workspace navigation">
      <Brand role={role} />{nav(false)}
    </aside>
    <div className="operator-workspace">
      <Topbar pseudonym={pseudonym} role={role} env={env} navigationControl={
        <><button ref={mobileButton} type="button" className="icon-btn operator-menu-toggle"
          aria-label="Open navigation" aria-haspopup="dialog" aria-expanded={mobileOpen}
          onClick={() => setMobileOpen(true)}><Menu size={18} /></button>
          <button ref={searchButton} type="button" className="icon-btn shrink-0" aria-label="Find a page" aria-haspopup="dialog"
            aria-expanded={searchOpen}
            title="Find a page (Ctrl or Command + K)" onClick={() => setSearchOpen(true)}><Search size={18} /></button></>
      } />
      <div className="operator-context">
        <nav aria-label="Breadcrumb" className="operator-breadcrumb">
          <span>{active?.group ?? "Workspace"}</span><span aria-hidden="true">/</span>
          {active && pathname !== active.href ? <><Link href={active.href} prefetch={false}>{active.label}</Link><span aria-hidden="true">/</span><span aria-current="page">Details</span></> :
            <span aria-current="page">{active?.label ?? "Page"}</span>}
        </nav>
        <div className="operator-context-actions">
          <button type="button" className="btn-ghost" aria-pressed={compact}
            onClick={() => setCompact(value => !value)}>{compact ? "Comfortable view" : "Compact view"}</button>
          {active && <button type="button" className="btn-ghost" aria-pressed={isFavorite}
            disabled={!isFavorite && allowedFavorites.length >= 8}
            title="Save up to eight pages for this workspace session"
            onClick={() => setFavorites(isFavorite ? allowedFavorites.filter(href => href !== active.href) : [...allowedFavorites, active.href])}>
            <Star size={15} fill={isFavorite ? "currentColor" : "none"} />{isFavorite ? "Saved" : "Favorite"}
          </button>}
        </div>
      </div>
      <main id="workspace-content" tabIndex={-1} className="operator-main">{children}</main>
    </div>
    {mobileOpen && <NavigationDialog onClose={() => setMobileOpen(false)}>
      <Brand role={role} />{nav(true)}
    </NavigationDialog>}
    {searchOpen && <PageSearch role={role} onClose={() => setSearchOpen(false)} />}
  </div>;
}

function Brand({ role }: { role: string }) {
  return <Link href="/overview" prefetch={false} className="operator-brand">
    {/* Extracted original reference artwork; no external image host. */}
    <img src="/design/operator-shell/cutout-4-2ee7a58500c2.png" width={44} height={44} alt="" />
    <span><strong>Venttly</strong><small>{role.replaceAll("_", " ")}</small></span>
  </Link>;
}

function ShellNavigation({ role, pathname, favorites, badges, mobile, onNavigate }: {
  role: string; pathname: string; favorites: string[]; badges: Partial<Record<string, ReactNode>>;
  mobile: boolean; onNavigate: () => void;
}) {
  const active = activeNavigation(role, pathname);
  const pages = visibleNavigation(role);
  const { data: attention, queuesAvailable } = useStaffAttention();
  const destination = (href: string) => attentionDestination(href, attention, queuesAvailable);
  const [expanded, setExpanded] = useState<Record<string, boolean>>({ [active?.group ?? "Command Center"]: true });
  useEffect(() => {
    if (active) setExpanded(previous => ({ ...previous, [active.group]: true }));
  }, [pathname, active?.group]);
  const item = (href: string, label: string, badge = true) => <Link key={href} href={badge ? destination(href) : href} prefetch={false}
    aria-current={active?.href === href ? "page" : undefined} onClick={onNavigate}
    className="operator-page-link"><span>{label}</span>{badge && badges[href]}<Pending /></Link>;
  return <nav className="operator-navigation" aria-label={mobile ? "Mobile pages" : "Pages"}>
    {favorites.length > 0 && <section className="operator-favorites" aria-label="Favorites">
      <p className="h-eyebrow">Favorites · this session</p>
      {pages.filter(page => favorites.includes(page.href)).map(page => item(page.href, page.label, false))}
    </section>}
    {navigationGroups.map((group, index) => {
      const visible = pages.filter(page => page.group === group.label);
      if (!visible.length) return null;
      const Icon = groupIcons[index];
      const id = `operator-${mobile ? "mobile" : "desktop"}-group-${index}`;
      return <section key={group.label} className="operator-nav-group">
        <button type="button" aria-expanded={!!expanded[group.label]} aria-controls={id}
          className={`operator-group-button ${active?.group === group.label ? "is-current" : ""}`}
          onClick={() => setExpanded(previous => ({ ...previous, [group.label]: !previous[group.label] }))}>
          {Icon ? <Icon size={19} aria-hidden="true" /> : <img src="/design/operator-shell/cutout-28-36a4f64d61ee.png" width={20} height={16} alt="" />}
          <span>{group.label}</span><ChevronDown size={14} aria-hidden="true" className={expanded[group.label] ? "rotate-180" : ""} />
        </button>
        <div id={id} hidden={!expanded[group.label]} className="operator-group-pages">
          {visible.map(page => item(page.href, page.label))}
        </div>
      </section>;
    })}
    <p className="operator-nav-note">Your role determines available controls.</p>
  </nav>;
}

function Pending() {
  const { pending } = useLinkStatus();
  return <span className={`operator-link-pending ${pending ? "is-pending" : ""}`} role="status">
    <span className="sr-only">{pending ? "Opening workspace…" : ""}</span>
  </span>;
}

function NavigationDialog({ children, onClose }: { children: ReactNode; onClose: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => { ref.current?.showModal(); }, []);
  // Native dialog supplies focus containment, Escape and background inertness.
  return <dialog ref={ref} className="operator-mobile-dialog" aria-label="Workspace navigation"
    onKeyDown={containDialogTab}
    onCancel={event => { event.preventDefault(); onClose(); }} onClose={onClose}
    onClick={event => { if (event.target === event.currentTarget) {
      const rect = event.currentTarget.getBoundingClientRect();
      if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) onClose();
    } }}>
    <button type="button" className="icon-btn operator-close-navigation" aria-label="Close navigation" onClick={onClose}><X size={18} /></button>
    {children}
  </dialog>;
}
