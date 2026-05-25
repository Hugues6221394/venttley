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

/**
 * Sliding-window rate limiter. Returns a thin wrapper so we can no-op
 * cleanly when Redis isn't configured (callers see `success: true`).
 */
export function createRateLimiter(
  prefix: string,
  limit: number,
  windowSeconds: number,
) {
  if (!redis) {
    return {
      async limit(_key: string) {
        return { success: true, remaining: limit, reset: 0, limit } as const;
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
