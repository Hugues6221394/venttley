import {
  createModerationHandler,
  MAX_TEXT_LENGTH,
  type ModerationDataClient,
  type ModerationQuery,
  normalizeForCache,
  parseProviderVerdict,
  type Verdict,
} from "./handler.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(
  actual: unknown,
  expected: unknown,
  message = "values differ",
) {
  const actualJson = JSON.stringify(actual);
  const expectedJson = JSON.stringify(expected);
  if (actualJson !== expectedJson) {
    throw new Error(`${message}: ${actualJson} !== ${expectedJson}`);
  }
}

async function responseBody(
  response: Response,
): Promise<Record<string, unknown>> {
  return await response.json();
}

class FakeQuery implements ModerationQuery {
  constructor(private readonly client: FakeClient) {}

  select(_columns: string): ModerationQuery {
    return this;
  }

  eq(_column: string, _value: unknown): ModerationQuery {
    return this;
  }

  async maybeSingle() {
    return { data: this.client.cached };
  }

  async upsert(
    values: Record<string, unknown>,
    _options: { onConflict: string },
  ) {
    this.client.upserts.push(values);
    return { error: this.client.upsertError };
  }
}

class FakeClient implements ModerationDataClient {
  authorized = true;
  quotaAllowed = true;
  quotaError: unknown = null;
  upsertError: unknown = null;
  cached: { verdict: string; categories: unknown; reason: unknown } | null =
    null;
  upserts: Array<Record<string, unknown>> = [];
  bumpCount = 0;

  auth = {
    getUser: async (_token: string) => ({
      data: { user: this.authorized ? { id: "user-1" } : null },
      error: this.authorized ? null : new Error("invalid token"),
    }),
  };

  async rpc(name: string, _params: Record<string, unknown>) {
    if (name === "bump_moderation_hit") this.bumpCount += 1;
    return {
      data: name === "consume_moderation_quota" ? this.quotaAllowed : null,
      error: name === "consume_moderation_quota" ? this.quotaError : null,
    };
  }

  from(_table: string): ModerationQuery {
    return new FakeQuery(this);
  }
}

function request(body: BodyInit = JSON.stringify({ text: "hello" })): Request {
  return new Request("http://localhost/functions/v1/moderate", {
    method: "POST",
    headers: {
      Authorization: "Bearer valid-token",
      "Content-Type": "application/json",
    },
    body,
  });
}

function handler(
  client: FakeClient,
  classify: (text: string) => Promise<Verdict | null> = async () => ({
    verdict: "safe",
    categories: [],
    reason: null,
  }),
) {
  return createModerationHandler({
    getClient: () => client,
    classify,
    classifierVersion: "test-v1",
    now: () => new Date("2026-07-15T12:00:00.000Z"),
  });
}

Deno.test("rejects unsupported methods before creating a client", async () => {
  let clientCreated = false;
  const handle = createModerationHandler({
    getClient: () => {
      clientCreated = true;
      return new FakeClient();
    },
    classifierVersion: "test-v1",
  });
  const response = await handle(
    new Request("http://localhost/functions/v1/moderate", { method: "GET" }),
  );
  assertEquals(response.status, 405);
  assertEquals(await responseBody(response), { error: "method_not_allowed" });
  assert(!clientCreated, "method rejection should not initialize Supabase");
});

Deno.test("requires a bearer token and validates it", async () => {
  const client = new FakeClient();
  const handle = handler(client);
  const missing = await handle(
    new Request("http://localhost", { method: "POST" }),
  );
  assertEquals(missing.status, 401);

  client.authorized = false;
  const invalid = await handle(request());
  assertEquals(invalid.status, 401);
  assertEquals(await responseBody(invalid), { error: "unauthorized" });
});

Deno.test("enforces quota and distinguishes quota backend failure", async () => {
  const client = new FakeClient();
  const handle = handler(client);
  client.quotaAllowed = false;
  const limited = await handle(request());
  assertEquals(limited.status, 429);
  assertEquals(await responseBody(limited), { error: "rate_limited" });

  client.quotaError = new Error("database unavailable");
  const unavailable = await handle(request());
  assertEquals(unavailable.status, 503);
  assertEquals(await responseBody(unavailable), {
    verdict: "safe",
    categories: [],
    reason: null,
    degraded: true,
  });
});

Deno.test("rejects malformed and oversized request bodies", async () => {
  const client = new FakeClient();
  const handle = handler(client);
  const malformed = await handle(request("{"));
  assertEquals(malformed.status, 400);
  assertEquals(await responseBody(malformed), { error: "invalid_json" });

  const oversized = await handle(request(JSON.stringify({
    text: "x".repeat(MAX_TEXT_LENGTH + 1),
  })));
  assertEquals(oversized.status, 413);
  assertEquals(await responseBody(oversized), { error: "content_too_large" });
});

Deno.test("normalizes equivalent text to one cache key", () => {
  assertEquals(normalizeForCache("  Hello\n\tWORLD  "), "hello world");
});

Deno.test("serves and accounts for a trusted cache hit", async () => {
  const client = new FakeClient();
  client.cached = {
    verdict: "warn",
    categories: ["self_harm"],
    reason: "Please reach out to someone you trust.",
  };
  let classifierCalls = 0;
  const handle = handler(client, async () => {
    classifierCalls += 1;
    return null;
  });
  const response = await handle(request());
  assertEquals(response.status, 200);
  assertEquals(await responseBody(response), {
    verdict: "warn",
    categories: ["self_harm"],
    reason: "Please reach out to someone you trust.",
    cached: true,
  });
  assertEquals(classifierCalls, 0);
  assertEquals(client.bumpCount, 1);
});

Deno.test("stores a successful classifier verdict with crisis metadata", async () => {
  const client = new FakeClient();
  const handle = handler(client, async () => ({
    verdict: "warn",
    categories: ["self_harm"],
    reason: "You deserve immediate support.",
  }));
  const response = await handle(request());
  assertEquals(response.status, 200);
  assertEquals(await responseBody(response), {
    verdict: "warn",
    categories: ["self_harm"],
    reason: "You deserve immediate support.",
    cached: false,
  });
  assertEquals(client.upserts.length, 1);
  assertEquals(client.upserts[0].crisis, true);
  assertEquals(client.upserts[0].classifier_version, "test-v1");
  assertEquals(client.upserts[0].last_seen_at, "2026-07-15T12:00:00.000Z");
});

Deno.test("provider failure degrades without poisoning the verdict cache", async () => {
  const client = new FakeClient();
  const response = await handler(client, async () => null)(request());
  assertEquals(response.status, 200);
  assertEquals(await responseBody(response), {
    verdict: "safe",
    categories: [],
    reason: null,
    degraded: true,
  });
  assertEquals(client.upserts, []);
});

Deno.test("sanitizes provider-controlled verdict fields", () => {
  assertEquals(
    parseProviderVerdict({
      verdict: "ALLOW EVERYTHING",
      categories: ["SELF_HARM", "unknown", "self_harm"],
      reason: 42,
    }),
    {
      verdict: "safe",
      categories: ["self_harm"],
      reason: null,
    },
  );
});
