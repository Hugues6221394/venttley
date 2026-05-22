export default function StatCard({
  label,
  value,
  sub,
  tone = "default",
}: {
  label: string;
  value: string | number;
  sub?: string;
  tone?: "default" | "ok" | "warn" | "danger";
}) {
  const toneClass =
    tone === "ok"
      ? "text-ok"
      : tone === "warn"
        ? "text-warn"
        : tone === "danger"
          ? "text-danger"
          : "text-berry";
  return (
    <div className="card p-5 flex flex-col gap-2">
      <p className="text-[11px] font-bold uppercase tracking-widest text-burgundy/60">
        {label}
      </p>
      <p className={`text-3xl font-extrabold leading-none ${toneClass}`}>
        {typeof value === "number" ? value.toLocaleString() : value}
      </p>
      {sub && <p className="text-xs text-burgundy/65">{sub}</p>}
    </div>
  );
}
