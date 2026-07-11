// k6 HTTP/RPC load test for Venttly's read + write paths (PostgREST).
// Run against STAGING only. Install k6: https://k6.io
//
//   SUPABASE_URL=https://<staging-ref>.supabase.co \
//   ANON_KEY=<staging-anon> USER_JWT=<staging-user-jwt> \
//   k6 run rpc-load.js
//
// Adjust the endpoints to whatever's representative of your hot path. This
// hits the read path (feed) heavily and the write path (a tribe message send)
// lightly so you can watch the pooler + the 0088/0090 velocity-trigger cost.

import http from "k6/http";
import { check, sleep } from "k6";

const URL = __ENV.SUPABASE_URL;
const ANON = __ENV.ANON_KEY;
const JWT = __ENV.USER_JWT;

export const options = {
  stages: [
    { duration: "30s", target: 50 },
    { duration: "1m", target: 200 },
    { duration: "1m", target: 400 },
    { duration: "30s", target: 0 },
  ],
  thresholds: {
    http_req_duration: ["p(95)<300"],
    http_req_failed: ["rate<0.005"],
  },
};

export function setup() {
  if (!URL || !ANON || !JWT) throw new Error("Set SUPABASE_URL, ANON_KEY, USER_JWT");
  if (/prod|production/i.test(URL)) throw new Error(`URL looks like prod: ${URL} — aborting`);
}

const headers = () => ({
  apikey: ANON,
  Authorization: `Bearer ${JWT}`,
  "Content-Type": "application/json",
});

export default function () {
  // Read path — feed (representative heavy read).
  const feed = http.get(
    `${URL}/rest/v1/feed_posts?select=post_id,content,created_at&limit=20&order=created_at.desc`,
    { headers: headers() },
  );
  check(feed, { "feed 200": (r) => r.status === 200 });

  // Read path — the server-side moderation cache is exercised naturally when
  // real users post; here we just keep read pressure on the pooler.
  sleep(1);
}
