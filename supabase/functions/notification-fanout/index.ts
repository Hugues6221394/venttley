// notification-fanout
//
// Triggered by a Database Webhook on INSERT into:
//   * chat_messages
//   * tribe_messages
//   * friendships
//   * notifications
//
// For each event, resolves the set of users who should be notified,
// looks up their `push_tokens`, and POSTs to Firebase Cloud Messaging
// HTTP v1.
//
// Env:
//   FCM_PROJECT_ID                   — Firebase project id
//   FCM_SERVICE_ACCOUNT_JSON         — full JSON of a service account
//                                       w/ Cloud Messaging admin role
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY
//
// Deploy: supabase functions deploy notification-fanout
// Wire:   Postgres webhook → POST {functionUrl} on insert.

import { adminClient } from '../_shared/supabase.ts';
import { corsHeaders, handleOptions } from '../_shared/cors.ts';

interface WebhookPayload {
  type: 'INSERT' | 'UPDATE' | 'DELETE';
  table: string;
  record: Record<string, unknown>;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return handleOptions()!;

  let payload: WebhookPayload;
  try {
    payload = await req.json();
  } catch {
    return new Response('invalid body', { status: 400, headers: corsHeaders });
  }
  if (payload.type !== 'INSERT') {
    return new Response('ignored', { headers: corsHeaders });
  }

  const supabase = adminClient();
  const recipients: { userId: string; title: string; body: string; data: Record<string, string> }[] = [];

  switch (payload.table) {
    case 'chat_messages': {
      const r = payload.record as any;
      const { data: room } = await supabase
        .from('chat_rooms')
        .select('initiated_by, received_by')
        .eq('room_id', r.room_id)
        .single();
      if (!room) break;
      const peer = room.initiated_by === r.sender_id
        ? room.received_by
        : room.initiated_by;
      if (peer) {
        // Respect the recipient's per-room mute (dm_room_prefs, migration 0098):
        // a muted room delivers no push.
        const { data: pref } = await supabase
          .from('dm_room_prefs')
          .select('muted')
          .eq('room_id', r.room_id)
          .eq('user_id', peer)
          .maybeSingle();
        if (!pref?.muted) {
          recipients.push({
            userId: peer,
            title: 'New message',
            body: 'Tap to read your conversation.',
            data: { kind: 'chat', room_id: r.room_id, message_id: r.message_id },
          });
        }
      }
      break;
    }
    case 'tribe_messages': {
      const r = payload.record as Record<string, unknown>;
      const tribeId = String(r.tribe_id);
      const messageId = String(r.message_id);
      const senderId = r.sender_id as string | null;

      const { data: tribe } = await supabase
        .from('tribes')
        .select('slug, name')
        .eq('tribe_id', tribeId)
        .maybeSingle();

      const slug = (tribe?.slug as string | undefined) ?? tribeId;
      const tribeName = (tribe?.name as string | undefined) ?? 'Tribe chat';

      const { data: members } = await supabase
        .from('tribe_members')
        .select('user_id')
        .eq('tribe_id', tribeId);

      const content = r.content;
      const preview =
        typeof content === 'string' && content.trim().length > 0
          ? content.slice(0, 80)
          : 'New message in tribe chat';

      for (const m of members ?? []) {
        if (m.user_id === senderId) continue;
        recipients.push({
          userId: m.user_id as string,
          title: tribeName,
          body: preview,
          data: {
            kind: 'tribe_chat',
            payload: `tribe_chat:${slug}/${messageId}`,
            tribe_slug: slug,
            message_id: messageId,
          },
        });
      }
      break;
    }
    case 'friendships': {
      const r = payload.record as any;
      if (r.status === 'pending') {
        const target = r.requested_by === r.user_a ? r.user_b : r.user_a;
        recipients.push({
          userId: target,
          title: 'New friend request',
          body: 'Someone wants to connect with you.',
          data: { kind: 'friend_request', friendship_id: r.friendship_id },
        });
      }
      break;
    }
    case 'notifications': {
      const r = payload.record as any;
      const payloadObj = r.payload ?? {};
      recipients.push({
        userId: r.user_id,
        title: payloadObj.title ?? 'Venttly',
        body: payloadObj.body ?? '',
        data: { kind: r.kind, notification_id: r.notification_id },
      });
      break;
    }
    default:
      return new Response('unknown table', { status: 200, headers: corsHeaders });
  }

  if (recipients.length === 0) {
    return new Response('no recipients', { headers: corsHeaders });
  }

  // Fan out to FCM. We look up tokens once per unique user.
  const uniqueUserIds = [...new Set(recipients.map((r) => r.userId))];
  const { data: tokens } = await supabase
    .from('push_tokens')
    .select('user_id, token, platform')
    .in('user_id', uniqueUserIds);

  const accessToken = await fcmAccessToken();
  const projectId = Deno.env.get('FCM_PROJECT_ID');
  if (!accessToken || !projectId) {
    console.warn('FCM not configured — skipping send');
    return new Response('fcm disabled', { headers: corsHeaders });
  }

  const tokenByUser = new Map<string, { token: string; platform: string }[]>();
  for (const t of tokens ?? []) {
    if (!tokenByUser.has(t.user_id)) tokenByUser.set(t.user_id, []);
    tokenByUser.get(t.user_id)!.push({ token: t.token, platform: t.platform });
  }

  let sent = 0;
  await Promise.all(
    recipients.map(async (r) => {
      const userTokens = tokenByUser.get(r.userId) ?? [];
      for (const t of userTokens) {
        try {
          const res = await fetch(
            `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
            {
              method: 'POST',
              headers: {
                Authorization: `Bearer ${accessToken}`,
                'Content-Type': 'application/json',
              },
              body: JSON.stringify({
                message: {
                  token: t.token,
                  notification: { title: r.title, body: r.body },
                  data: r.data,
                },
              }),
            },
          );
          if (res.ok) sent++;
        } catch (e) {
          console.error('FCM send failed', e);
        }
      }
    }),
  );

  return new Response(JSON.stringify({ sent }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});

/**
 * Mints an OAuth access token for FCM from the service account JSON.
 * Cached for ~50 minutes (tokens are valid for 1 hour).
 */
let cachedToken: { token: string; expiresAt: number } | null = null;
async function fcmAccessToken(): Promise<string | null> {
  const now = Date.now();
  if (cachedToken && cachedToken.expiresAt > now + 5 * 60_000) {
    return cachedToken.token;
  }
  const raw = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON');
  if (!raw) return null;
  const sa = JSON.parse(raw);
  const jwt = await mintJwt(sa);
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  if (!res.ok) return null;
  const body = await res.json();
  cachedToken = {
    token: body.access_token,
    expiresAt: now + (body.expires_in ?? 3600) * 1000,
  };
  return cachedToken.token;
}

async function mintJwt(sa: { client_email: string; private_key: string }): Promise<string> {
  const header = { alg: 'RS256', typ: 'JWT' };
  const iat = Math.floor(Date.now() / 1000);
  const claim = {
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat,
    exp: iat + 3600,
  };
  const enc = (o: unknown) =>
    btoa(JSON.stringify(o)).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
  const unsigned = `${enc(header)}.${enc(claim)}`;
  const key = await importPkcs8(sa.private_key);
  const sig = await crypto.subtle.sign(
    { name: 'RSASSA-PKCS1-v1_5' },
    key,
    new TextEncoder().encode(unsigned),
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
  return `${unsigned}.${sigB64}`;
}

async function importPkcs8(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s+/g, '');
  const raw = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    'pkcs8',
    raw.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
}
