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
  const dot =
    tone === "ok"
      ? "rgb(var(--console-ok))"
      : tone === "warn"
        ? "rgb(var(--console-warn))"
        : tone === "danger"
          ? "rgb(var(--console-danger))"
          : undefined;
  const zero = value === 0 || value === "0";
  return (
    <div className="kpi">
      <p className="kpi-label">
        <span className="kpi-tone" style={dot ? { background: dot } : undefined} aria-hidden="true" />
        {label}
      </p>
      <p className={`kpi-value ${zero ? "is-zero" : ""}`}>
        {typeof value === "number" ? value.toLocaleString() : value}
      </p>
      {sub && <p className="kpi-sub">{sub}</p>}
    </div>
  );
}
