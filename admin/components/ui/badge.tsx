import type { ReactNode } from "react";
import type { Tone } from "./stat-card";

const map: Record<Tone, string> = {
  neutral: "bg-canvas text-ink-muted",
  ok: "bg-ok/10 text-ok",
  warn: "bg-warn/10 text-warn",
  danger: "bg-danger/10 text-danger",
  info: "bg-info/10 text-info",
  crisis: "bg-danger text-white",
};

export function Badge({
  tone = "neutral",
  children,
  icon,
  className = "",
}: {
  tone?: Tone;
  children: ReactNode;
  icon?: ReactNode;
  className?: string;
}) {
  return (
    <span className={`pill ${icon ? "" : "pill-dot"} ${map[tone]} ${className}`}>
      {icon}
      {children}
    </span>
  );
}

export type { Tone };
