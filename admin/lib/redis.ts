import { Redis } from "@upstash/redis";
import { Ratelimit } from "@upstash/ratelimit";

/**
 * Upstash Redis layer for the admin app.
 *
 * Cross-instance counters + edge rate limits without running our own
 * Redis. Both env vars must be set; when either is missing, every
 * helper here returns a graceful no-op so dev / preview builds keep
 * working without provisioning Upstash.
 *
 * Provision a free database at https://console.upstash.com and copy
 *   UPSTASH_REDIS_REST_URL=
 *   UPSTASH_REDIS_REST_TOKEN=
 * into admin/.env.local.
 */

const url = process.env.UPSTASH_REDIS_REST_URL;
const token = process.env.UPSTASH_REDIS_REST_TOKEN;

export const redis: Redis | null =
  url && token ? new Redis({ url, token }) : null;

export const isRedisConfigured = redis !== null;

const IS_PRODUCTION = process.env.NODE_ENV === "production";

/**
 * What a limiter does when Redis is not configured.
 *
 * This used to be one answer for everything — report success, let the request
 * through — which meant a deployment missing two env vars had no rate limiting
 * on login, on audit export, or on privileged writes, and nothing anywhere
 * said so. The README already lists Upstash as required before internet
 * exposure; nothing enforced it.
 *
 * "Fail closed" is not the right answer everywhere either, so each call site
 * declares which it is:
 *
 *   "deny"         — refuse the request. For controls whose absence is the
 *                    vulnerability: unlimited login attempts against an admin
 *                    console, or uncapped export of the audit log. Refusing
 *                    turns a silent hole into an obvious deployment failure,
 *                    and the fix is one environment variable.
 *
 *   "allow-loudly" — run anyway and log every occurrence. For moderator work.
 *                    Stopping someone from acting on a self-harm case because
 *                    a cache is unconfigured trades a small abuse risk for a
 *                    real safety harm, and that is not a trade this file gets
 *                    to make quietly.
 *
 * Outside production the limiter stays permissive so local development works
 * without provisioning Upstash, with one warning at load rather than per call.
 */
export type UnconfiguredPolicy = "deny" | "allow-loudly";

if (!redis && IS_PRODUCTION) {
  console.error(
    "[redis] UPSTASH_REDIS_REST_URL/TOKEN are unset in production. " +
      "Rate limiting is unavailable: login and audit export will refuse " +
      "requests, and privileged writes will run unthrottled."
  );
} else if (!redis) {
  console.warn(
    "[redis] Upstash not configured — rate limiting is permissive. " +
      "Fine locally; this would refuse logins in production."
  );
}

/** Whether rate limiting is actually enforced right now. For /system. */
export function rateLimitingStatus(): {
  enforced: boolean;
  detail: string;
} {
  if (redis) return { enforced: true, detail: "Upstash reachable" };
  return IS_PRODUCTION
    ? {
        enforced: false,
        detail:
          "NOT ENFORCED — Upstash unset in production. Login and audit export are refusing requests.",
      }
    : {
        enforced: false,
        detail: "Not enforced (no Upstash) — permissive outside production.",
      };
}

/**
 * Sliding-window rate limiter. When Redis isn't configured the behaviour is
 * decided by `whenUnconfigured` — see UnconfiguredPolicy above.
 */
export function createRateLimiter(
  prefix: string,
  limit: number,
  windowSeconds: number,
  whenUnconfigured: UnconfiguredPolicy = "deny",
) {
  if (!redis) {
    const denyInProduction = IS_PRODUCTION && whenUnconfigured === "deny";
    return {
      async limit(_key: string) {
        if (denyInProduction) {
          console.error(
            `[redis] refusing "${prefix}": rate limiting is unavailable and this control fails closed. ` +
              `Set UPSTASH_REDIS_REST_URL and UPSTASH_REDIS_REST_TOKEN.`
          );
          // `unavailable` separates "you have made too many attempts" from
          // "this control cannot run". Callers must not report the former for
          // the latter: it tells an operator to wait, when waiting never fixes
          // it, and the page that would explain why is behind the login this
          // is refusing.
          return {
            success: false,
            unavailable: true,
            remaining: 0,
            reset: 0,
            limit,
          } as const;
        }
        if (IS_PRODUCTION) {
          console.error(
            `[redis] "${prefix}" ran UNTHROTTLED: rate limiting is unavailable.`
          );
        }
        return {
          success: true,
          unavailable: false,
          remaining: limit,
          reset: 0,
          limit,
        } as const;
      },
    };
  }
  const rl = new Ratelimit({
    redis,
    limiter: Ratelimit.slidingWindow(limit, `${windowSeconds} s`),
    analytics: true,
    prefix,
  });
  return {
    async limit(key: string) {
      const r = await rl.limit(key);
      return {
        success: r.success,
        unavailable: false,
        remaining: r.remaining,
        reset: r.reset,
        limit: r.limit,
      } as const;
    },
  };
}

/**
 * Cross-instance counter. INCRs `counter:<bucket>:<key>` and returns
 * the new value. Returns -1 when Redis isn't configured so callers
 * can branch on "no telemetry available".
 */
export async function incrementCounter(
  bucket: string,
  key: string,
  ttlSeconds?: number,
): Promise<number> {
  if (!redis) return -1;
  const k = `counter:${bucket}:${key}`;
  const value = await redis.incr(k);
  if (ttlSeconds && value === 1) await redis.expire(k, ttlSeconds);
  return value;
}

/**
 * Best-effort IP extraction from a Next.js Request. Falls back to a
 * bucket so the limiter still works in dev where the IP is missing.
 */
export function ipFrom(req: Request): string {
  const xf = req.headers.get("x-forwarded-for");
  if (xf) return xf.split(",")[0]!.trim();
  const real = req.headers.get("x-real-ip");
  if (real) return real;
  return "unknown";
}
