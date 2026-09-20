import "server-only";

/** Opt-in diagnostic timings only. Never emits URLs, query strings, table
 * names, identifiers, request/response bodies, tokens, or authored content.
 * This measures HTTP round trips (including transport), not Postgres CPU time.
 */
export const measuredSupabaseFetch: typeof fetch = async (input, init) => {
  const started = performance.now();
  let status: number | null = null;
  try {
    const response = await fetch(input, init);
    status = response.status;
    return response;
  } finally {
    if (process.env.ADMIN_PROFILE_METRICS === "1") {
      let category = "other";
      try {
        const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
        category = url.pathname.startsWith("/auth/") ? "auth"
          : url.pathname.startsWith("/rest/v1/rpc/") ? "rpc"
          : url.pathname.startsWith("/rest/") ? "query" : "other";
      } catch { /* Unclassifiable input still never gets logged. */ }
      console.info("ADMIN_TIMING " + JSON.stringify({ category, durationMs: Math.round((performance.now()-started)*100)/100, status }));
    }
  }
};
