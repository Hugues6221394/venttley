// Presentation-only colour band for open-queue counts. Not an SLA or priority.
export const highQueueCount = 20;

export function queueUrgency(count: number | null | undefined): "is-zero" | "is-open" | "is-high" | "" {
  if (typeof count !== "number") return "";
  if (count === 0) return "is-zero";
  return count >= highQueueCount ? "is-high" : "is-open";
}
