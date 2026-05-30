import type { ReactNode } from "react";
import type { Tone } from "./stat-card";

const map: Record<Tone, string> = {
  neutral: "bg-line text-ink-muted",
  ok: "bg-ok/12 text-ok",
  warn: "bg-warn/15 text-warn",
  danger: "bg-danger/12 text-danger",
  info: "bg-info/12 text-info",
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
    <span className={`pill ${map[tone]} ${className}`}>
      {icon}
      {children}
    </span>
  );
}

export type { Tone };
