/**
 * Enough of an address to recognise which inbox to open, not enough to learn
 * it. The domain is shown whole; the local part keeps at most two letters at
 * each end and never less than two characters hidden, so a short local part is
 * not handed back in full. The run of dots is a fixed length so it does not
 * disclose the length either.
 */
const HIDDEN = "•••••";

export function maskEmail(address: string | null | undefined): string | null {
  const value = (address ?? "").trim();
  const at = value.lastIndexOf("@");
  if (at <= 0 || at === value.length - 1) return null;
  const local = Array.from(value.slice(0, at));
  const domain = value.slice(at + 1);
  const n = local.length;

  let shown: string;
  if (n >= 6) shown = local.slice(0, 2).join("") + HIDDEN + local.slice(-2).join("");
  else if (n >= 4) shown = local[0] + HIDDEN + local[n - 1];
  else if (n === 3) shown = local[0] + HIDDEN;
  else shown = HIDDEN;

  return `${shown}@${domain}`;
}
