// Durable, privacy-preserving push delivery worker.
//
// Database Webhooks submit only an event table + primary key. Postgres
// re-reads the canonical row and idempotently expands recipients into the
// server-owned push_delivery_outbox. This worker then leases a bounded batch,
// sends generic copy (never user-authored text), and records success/retry.
//
// Auth: verify_jwt=false plus x-webhook-secret: <WEBHOOK_SECRET>.
// Rollout: PUSH_DELIVERY_ENABLED must be explicitly enabled.

import { adminClient } from "../_shared/supabase.ts";
import {
  rolloutEnabled,
  verifyInternalSecret,
} from "../_shared/internal_auth.ts";

interface WebhookPayload {
  type?: "INSERT" | "UPDATE" | "DELETE";
  table?: string;
  record?: Record<string, unknown>;
  batch?: number;
}

interface PushDelivery {
  delivery_id: string;
  attempts: number;
  user_id: string;
  event_kind: "chat" | "tribe_chat" | "friend_request" | "notification";
  event_data: Record<string, unknown> | null;
}

const EVENT_IDS: Record<string, string> = {
  chat_messages: "message_id",
  tribe_messages: "message_id",
  friendships: "friendship_id",
  notifications: "notification_id",
};

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const auth = verifyInternalSecret(request, {
    envName: "WEBHOOK_SECRET",
    headerName: "x-webhook-secret",
  });
  if (!auth.ok) return json({ error: auth.error }, auth.status);
  if (!rolloutEnabled("PUSH_DELIVERY_ENABLED")) {
    return json({ ok: false, disabled: true }, 503);
  }

  const payload = await request.json().catch(() => null) as
    | WebhookPayload
    | null;
  if (payload == null || typeof payload !== "object") {
    return json({ error: "invalid_body" }, 400);
  }

  const supabase = adminClient();
  let enqueued = 0;
  if (payload.record != null || payload.table != null || payload.type != null) {
    if (payload.type !== "INSERT" || !payload.table || !payload.record) {
      return json({ error: "invalid_webhook_event" }, 400);
    }
    const idColumn = EVENT_IDS[payload.table];
    const eventId = idColumn == null ? null : payload.record[idColumn];
    if (
      idColumn == null || typeof eventId !== "string" || eventId.length === 0
    ) {
      return json({ error: "unsupported_webhook_event" }, 400);
    }
    const enqueue = await supabase.rpc("enqueue_push_event", {
      p_table: payload.table,
      p_event_id: eventId,
    });
    if (enqueue.error) {
      console.error(
        "push enqueue failed",
        enqueue.error.code ?? "database_error",
      );
      return json({ error: "enqueue_failed" }, 500);
    }
    enqueued = typeof enqueue.data === "number" ? enqueue.data : 0;
  }

  const batch = clamp(
    typeof payload.batch === "number" ? payload.batch : 100,
    1,
    250,
  );
  const claimed = await supabase.rpc("claim_push_deliveries", {
    p_batch: batch,
  });
  if (claimed.error) {
    console.error("push claim failed", claimed.error.code ?? "database_error");
    return json({ error: "claim_failed" }, 500);
  }
  const deliveries = (claimed.data ?? []) as PushDelivery[];
  if (deliveries.length === 0) {
    return json({ ok: true, enqueued, claimed: 0, sent: 0, retried: 0 });
  }

  const userIds = [...new Set(deliveries.map((delivery) => delivery.user_id))];
  const tokenResult = await supabase
    .from("push_tokens")
    .select("user_id, token, platform")
    .in("user_id", userIds);
  if (tokenResult.error) {
    await releaseAll(supabase, deliveries, "token_lookup_failed");
    return json({ error: "token_lookup_failed" }, 500);
  }

  const tokensByUser = new Map<string, string[]>();
  for (const row of tokenResult.data ?? []) {
    if (!tokensByUser.has(row.user_id)) tokensByUser.set(row.user_id, []);
    tokensByUser.get(row.user_id)!.push(row.token);
  }

  const accessToken = await fcmAccessToken();
  const projectId = Deno.env.get("FCM_PROJECT_ID");
  if (!accessToken || !projectId) {
    await releaseAll(supabase, deliveries, "fcm_not_configured");
    return json({ error: "fcm_not_configured" }, 503);
  }

  let sent = 0;
  let retried = 0;
  await runPool(deliveries, 20, async (delivery) => {
    const tokens = tokensByUser.get(delivery.user_id) ?? [];
    if (tokens.length === 0) {
      await completeDelivery(
        supabase,
        delivery.delivery_id,
        delivery.attempts,
        true,
        "no_active_tokens",
      );
      return;
    }

    let deliveredToADevice = false;
    let retryableFailures = 0;
    for (const token of tokens) {
      const outcome = await sendPush(
        projectId,
        accessToken,
        token,
        delivery,
      );
      if (outcome === "invalid_token") {
        await supabase.from("push_tokens").delete()
          .eq("user_id", delivery.user_id)
          .eq("token", token);
      } else if (outcome === "retry") {
        retryableFailures++;
      } else {
        deliveredToADevice = true;
      }
    }

    // A user-level delivery succeeds once any active device accepted it. This
    // avoids duplicating a notification on a successful device merely because
    // another device had a transient failure. Retry only when every usable
    // token failed transiently.
    if (!deliveredToADevice && retryableFailures > 0) {
      retried++;
      await completeDelivery(
        supabase,
        delivery.delivery_id,
        delivery.attempts,
        false,
        "fcm_retryable",
      );
    } else {
      sent++;
      await completeDelivery(
        supabase,
        delivery.delivery_id,
        delivery.attempts,
        true,
        null,
      );
    }
  });

  return json({
    ok: true,
    enqueued,
    claimed: deliveries.length,
    sent,
    retried,
  });
});

async function sendPush(
  projectId: string,
  accessToken: string,
  token: string,
  delivery: PushDelivery,
): Promise<"sent" | "invalid_token" | "retry"> {
  const copy = notificationCopy(delivery.event_kind);
  const data = stringifyData(delivery.event_data ?? {});
  try {
    const response = await fetch(
      `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          message: {
            token,
            notification: copy,
            data: { kind: delivery.event_kind, ...data },
            android: { collapse_key: delivery.delivery_id },
            apns: {
              headers: { "apns-collapse-id": delivery.delivery_id },
            },
          },
        }),
        signal: AbortSignal.timeout(6000),
      },
    );
    if (response.ok) return "sent";
    if (response.status === 400 || response.status === 404) {
      return "invalid_token";
    }
    return "retry";
  } catch {
    return "retry";
  }
}

function notificationCopy(kind: PushDelivery["event_kind"]): {
  title: string;
  body: string;
} {
  switch (kind) {
    case "chat":
      return { title: "New message", body: "Tap to open your conversation." };
    case "tribe_chat":
      return { title: "New Tribe message", body: "Tap to open your Tribe." };
    case "friend_request":
      return { title: "New friend request", body: "Someone wants to connect." };
    case "notification":
    default:
      return {
        title: "New activity",
        body: "Open Venttly to see what happened.",
      };
  }
}

function stringifyData(data: Record<string, unknown>): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [key, value] of Object.entries(data)) {
    if (typeof value === "string" && value.length <= 256) result[key] = value;
  }
  return result;
}

async function completeDelivery(
  supabase: ReturnType<typeof adminClient>,
  deliveryId: string,
  attempt: number,
  succeeded: boolean,
  error: string | null,
): Promise<void> {
  const result = await supabase.rpc("complete_push_delivery", {
    p_delivery_id: deliveryId,
    p_attempt: attempt,
    p_succeeded: succeeded,
    p_error_code: error,
  });
  if (result.error) {
    console.error(
      "push completion failed",
      result.error.code ?? "database_error",
    );
  }
}

async function releaseAll(
  supabase: ReturnType<typeof adminClient>,
  deliveries: PushDelivery[],
  error: string,
): Promise<void> {
  await Promise.all(
    deliveries.map((delivery) =>
      completeDelivery(
        supabase,
        delivery.delivery_id,
        delivery.attempts,
        false,
        error,
      )
    ),
  );
}

async function runPool<T>(
  items: T[],
  concurrency: number,
  worker: (item: T) => Promise<void>,
): Promise<void> {
  let next = 0;
  const runners = Array.from(
    { length: Math.min(concurrency, items.length) },
    async () => {
      while (next < items.length) {
        const index = next++;
        await worker(items[index]);
      }
    },
  );
  await Promise.all(runners);
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(Math.trunc(value), minimum), maximum);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

let cachedToken: { token: string; expiresAt: number } | null = null;
async function fcmAccessToken(): Promise<string | null> {
  const now = Date.now();
  if (cachedToken && cachedToken.expiresAt > now + 5 * 60_000) {
    return cachedToken.token;
  }
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!raw) return null;
  try {
    const serviceAccount = JSON.parse(raw);
    const jwt = await mintJwt(serviceAccount);
    const response = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: jwt,
      }),
      signal: AbortSignal.timeout(6000),
    });
    if (!response.ok) return null;
    const body = await response.json();
    cachedToken = {
      token: body.access_token,
      expiresAt: now + (body.expires_in ?? 3600) * 1000,
    };
    return cachedToken.token;
  } catch {
    return null;
  }
}

async function mintJwt(
  serviceAccount: { client_email: string; private_key: string },
): Promise<string> {
  const issuedAt = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claim = {
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: issuedAt,
    exp: issuedAt + 3600,
  };
  const encode = (value: unknown) =>
    btoa(JSON.stringify(value)).replace(/=+$/, "").replace(/\+/g, "-").replace(
      /\//g,
      "_",
    );
  const unsigned = `${encode(header)}.${encode(claim)}`;
  const key = await importPkcs8(serviceAccount.private_key);
  const signature = await crypto.subtle.sign(
    { name: "RSASSA-PKCS1-v1_5" },
    key,
    new TextEncoder().encode(unsigned),
  );
  const encodedSignature = btoa(
    String.fromCharCode(...new Uint8Array(signature)),
  )
    .replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${unsigned}.${encodedSignature}`;
}

async function importPkcs8(pem: string): Promise<CryptoKey> {
  const bytes = Uint8Array.from(
    atob(pem.replace(/-----[^-]+-----|\s/g, "")),
    (character) => character.charCodeAt(0),
  );
  return crypto.subtle.importKey(
    "pkcs8",
    bytes,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}
