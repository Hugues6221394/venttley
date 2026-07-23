import { corsHeaders, handleOptions } from "../_shared/cors.ts";

const SYSTEM_PROMPT =
  "You are Venttly's safety reviewer for an anonymous emotional-support app. " +
  "Read the user message and return ONLY a compact JSON object with keys: " +
  'verdict ("safe"|"warn"|"block"), categories (array of any of ' +
  '"self_harm","hate","harassment","sexual_content","violence","privacy","other"), ' +
  "reason (one short sentence the user will read). Guidance: " +
  "- block hate speech, harassment of others, sexual solicitation, doxxing, " +
  "credible threats, sexual content involving minors. " +
  "- warn (do NOT block) when the writer expresses self-harm or suicidal " +
  "feelings - the user must still be able to reach out for help. " +
  "- safe for emotional venting, sadness, anger, swearing, or descriptions of " +
  "past trauma told in the first person.";

const ALLOWED_VERDICTS = new Set(["safe", "warn", "block"]);
const ALLOWED_CATEGORIES = new Set([
  "self_harm",
  "hate",
  "harassment",
  "sexual_content",
  "violence",
  "privacy",
  "other",
]);

export type Verdict = {
  verdict: "safe" | "warn" | "block";
  categories: string[];
  reason: string | null;
};

type CachedVerdict = {
  verdict: string;
  categories: unknown;
  reason: unknown;
};

export interface ModerationQuery {
  select(columns: string): ModerationQuery;
  eq(column: string, value: unknown): ModerationQuery;
  maybeSingle(): Promise<{ data: CachedVerdict | null; error?: unknown }>;
  upsert(
    values: Record<string, unknown>,
    options: { onConflict: string },
  ): PromiseLike<{ error?: unknown }>;
}

export interface ModerationDataClient {
  auth: {
    getUser(token: string): Promise<{
      data: { user: { id: string } | null };
      error: unknown;
    }>;
  };
  rpc(
    name: string,
    params: Record<string, unknown>,
  ): PromiseLike<{ data: unknown; error: unknown }>;
  from(table: string): ModerationQuery;
}

export interface ModerationHandlerDependencies {
  getClient: () => ModerationDataClient;
  classify?: (text: string) => Promise<Verdict | null>;
  classifierVersion?: string;
  now?: () => Date;
}

export const SAFE: Verdict = {
  verdict: "safe",
  categories: [],
  reason: null,
};
export const MAX_TEXT_LENGTH = 4000;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function sha256(value: string): Promise<string> {
  const buffer = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(buffer)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export function normalizeForCache(text: string): string {
  return text.trim().toLowerCase().replace(/\s+/g, " ");
}

export function parseProviderVerdict(value: unknown): Verdict {
  const body = value != null && typeof value === "object"
    ? value as Record<string, unknown>
    : {};
  const rawVerdict = typeof body.verdict === "string"
    ? body.verdict.toLowerCase()
    : "safe";
  const verdict = ALLOWED_VERDICTS.has(rawVerdict)
    ? rawVerdict as Verdict["verdict"]
    : "safe";
  const categories = Array.isArray(body.categories)
    ? [
      ...new Set(
        body.categories
          .map((category) => String(category).toLowerCase())
          .filter((category) => ALLOWED_CATEGORIES.has(category)),
      ),
    ]
    : [];
  const reason =
    typeof body.reason === "string" && body.reason.trim().length > 0
      ? body.reason.trim().slice(0, 280)
      : null;
  return { verdict, categories, reason };
}

export async function classifyWithGroq(text: string): Promise<Verdict | null> {
  const key = Deno.env.get("GROQ_API_KEY");
  if (!key) return null;
  const model = Deno.env.get("GROQ_GUARD_MODEL") ?? "llama-3.3-70b-versatile";
  try {
    const response = await fetch(
      "https://api.groq.com/openai/v1/chat/completions",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${key}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model,
          temperature: 0,
          max_tokens: 200,
          response_format: { type: "json_object" },
          messages: [
            { role: "system", content: SYSTEM_PROMPT },
            { role: "user", content: text },
          ],
        }),
        signal: AbortSignal.timeout(5000),
      },
    );
    if (!response.ok) return null;
    const body = await response.json();
    const content = body?.choices?.[0]?.message?.content;
    if (typeof content !== "string") return null;
    return parseProviderVerdict(JSON.parse(content));
  } catch {
    return null;
  }
}

export function createModerationHandler(
  dependencies: ModerationHandlerDependencies,
): (request: Request) => Promise<Response> {
  const classify = dependencies.classify ?? classifyWithGroq;
  const classifierVersion = dependencies.classifierVersion ??
    Deno.env.get("MODERATION_CLASSIFIER_VERSION") ?? "guard-v1";
  const now = dependencies.now ?? (() => new Date());

  return async (request: Request): Promise<Response> => {
    if (request.method === "OPTIONS") return handleOptions()!;
    if (request.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }

    const authorization = request.headers.get("Authorization");
    const token = authorization?.replace(/^Bearer\s+/i, "").trim();
    if (!token) return json({ error: "unauthorized" }, 401);

    const client = dependencies.getClient();
    const { data: authData, error: authError } = await client.auth.getUser(
      token,
    );
    if (authError || !authData.user) {
      return json({ error: "unauthorized" }, 401);
    }

    const { data: allowed, error: quotaError } = await client.rpc(
      "consume_moderation_quota",
      { p_user: authData.user.id },
    );
    if (quotaError) return json({ ...SAFE, degraded: true }, 503);
    if (allowed !== true) return json({ error: "rate_limited" }, 429);

    let text = "";
    try {
      text = String((await request.json())?.text ?? "");
    } catch {
      return json({ error: "invalid_json" }, 400);
    }
    if (!text.trim()) return json(SAFE);
    if (text.length > MAX_TEXT_LENGTH) {
      return json({ error: "content_too_large" }, 413);
    }

    const hash = await sha256(normalizeForCache(text));
    const { data: cached } = await client
      .from("moderation_verdicts")
      .select("verdict, categories, reason")
      .eq("content_hash", hash)
      .eq("classifier_version", classifierVersion)
      .maybeSingle();
    if (cached) {
      await client.rpc("bump_moderation_hit", { p_hash: hash });
      return json({
        ...parseProviderVerdict(cached),
        cached: true,
      });
    }

    // Provider failures never enter the trusted cache. Otherwise one outage
    // could turn into a durable stream of false-safe cache hits.
    const result = await classify(text);
    if (result === null) return json({ ...SAFE, degraded: true });

    const cacheWrite = await client.from("moderation_verdicts").upsert(
      {
        content_hash: hash,
        verdict: result.verdict,
        categories: result.categories,
        reason: result.reason,
        crisis: result.categories.includes("self_harm"),
        classifier_version: classifierVersion,
        last_seen_at: now().toISOString(),
      },
      { onConflict: "content_hash" },
    );
    if (cacheWrite.error) {
      console.error("moderation verdict cache write failed");
    }

    return json({ ...result, cached: false });
  };
}
