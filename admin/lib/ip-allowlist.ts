// IP allowlist for the admin console.
//
// Configured via the ADMIN_IP_ALLOWLIST env var: a comma-separated list of
// exact IPs and/or IPv4 CIDR blocks, e.g.
//   ADMIN_IP_ALLOWLIST="203.0.113.4, 198.51.100.0/24, 2001:db8::1"
//
// When the var is empty/unset the allowlist is DISABLED (allow all) so local
// dev and first-run don't lock anyone out. Set it in production to pin the
// console to office / VPN egress IPs.

function ipv4ToInt(ip: string): number | null {
  const parts = ip.trim().split(".");
  if (parts.length !== 4) return null;
  let n = 0;
  for (const p of parts) {
    const o = Number(p);
    if (!Number.isInteger(o) || o < 0 || o > 255) return null;
    n = (n << 8) | o;
  }
  return n >>> 0;
}

function matchesRule(ip: string, rule: string): boolean {
  const r = rule.trim();
  if (!r) return false;
  if (!r.includes("/")) return ip === r; // exact (v4 or v6)

  // IPv4 CIDR
  const [base, bitsStr] = r.split("/");
  const bits = Number(bitsStr);
  const ipInt = ipv4ToInt(ip);
  const baseInt = ipv4ToInt(base);
  if (ipInt === null || baseInt === null || !Number.isInteger(bits) || bits < 0 || bits > 32) {
    return false;
  }
  if (bits === 0) return true;
  const mask = bits === 32 ? 0xffffffff : (~((1 << (32 - bits)) - 1)) >>> 0;
  return (ipInt & mask) === (baseInt & mask);
}

export function allowlistConfigured(): boolean {
  return !!process.env.ADMIN_IP_ALLOWLIST?.trim();
}

/** True when `ip` is permitted. Allows everything when the allowlist is off. */
export function ipAllowed(ip: string | null): boolean {
  const raw = process.env.ADMIN_IP_ALLOWLIST?.trim();
  if (!raw) return true; // disabled
  if (!ip || ip === "unknown") return false; // allowlist on but no IP → deny
  const rules = raw.split(",").map((s) => s.trim()).filter(Boolean);
  return rules.some((rule) => matchesRule(ip, rule));
}
