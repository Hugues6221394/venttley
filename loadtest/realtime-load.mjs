// Realtime load test for Venttly — measures concurrent-connection ceiling and
// message fan-out latency against a STAGING Supabase project.
//
// Usage (see docs/realtime-load-test.md):
//   npm i @supabase/supabase-js
//   SUPABASE_URL=... SUPABASE_ANON_KEY=... CHANNEL=tribe:load-test \
//   SUBSCRIBERS=500 DURATION_SEC=120 PUBLISH_EVERY_MS=1000 STAGING_OK=1 \
//   node realtime-load.mjs
//
// SAFETY: refuses to run unless STAGING_OK=1, and warns loudly if the URL looks
// like production. Uses Realtime *broadcast* (no DB writes) so it isolates the
// realtime layer; adapt CHANNEL / add postgres_changes to mirror app topology.

import { createClient } from "@supabase/supabase-js";

const {
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  CHANNEL = "tribe:load-test",
  SUBSCRIBERS = "200",
  DURATION_SEC = "60",
  PUBLISH_EVERY_MS = "1000",
  STAGING_OK,
} = process.env;

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error("Set SUPABASE_URL and SUPABASE_ANON_KEY (staging).");
  process.exit(1);
}
if (STAGING_OK !== "1") {
  console.error("Refusing to run without STAGING_OK=1 (never load-test prod).");
  process.exit(1);
}
if (/prod|production/i.test(SUPABASE_URL)) {
  console.error(`URL looks like production: ${SUPABASE_URL} — aborting.`);
  process.exit(1);
}

const nSubs = parseInt(SUBSCRIBERS, 10);
const durationMs = parseInt(DURATION_SEC, 10) * 1000;
const publishEvery = parseInt(PUBLISH_EVERY_MS, 10);

const latencies = [];
let established = 0;
let refused = 0;
let published = 0;
let received = 0;

const subClients = [];

function pct(arr, p) {
  if (arr.length === 0) return 0;
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
}

async function makeSubscriber(i) {
  const c = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    realtime: { params: { eventsPerSecond: 20 } },
  });
  const ch = c.channel(CHANNEL, { config: { broadcast: { self: false } } });
  ch.on("broadcast", { event: "ping" }, ({ payload }) => {
    received++;
    if (payload?.t) latencies.push(Date.now() - payload.t);
  });
  await new Promise((resolve) => {
    ch.subscribe((status) => {
      if (status === "SUBSCRIBED") {
        established++;
        resolve();
      } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
        refused++;
        resolve();
      }
    });
    setTimeout(resolve, 10000); // don't hang forever on a stuck socket
  });
  subClients.push(c);
}

async function run() {
  console.log(
    `Connecting ${nSubs} subscribers to "${CHANNEL}" on ${SUPABASE_URL}…`,
  );
  // Ramp in small batches so we can see where connections start failing.
  const batch = 25;
  for (let i = 0; i < nSubs; i += batch) {
    await Promise.all(
      Array.from({ length: Math.min(batch, nSubs - i) }, (_, k) =>
        makeSubscriber(i + k),
      ),
    );
    process.stdout.write(`\r  established=${established} refused=${refused}`);
  }
  console.log(`\nSubscribed. Publishing for ${DURATION_SEC}s…`);

  // A separate publisher client broadcasts timestamped pings.
  const pub = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const pubCh = pub.channel(CHANNEL);
  await new Promise((r) => pubCh.subscribe((s) => s === "SUBSCRIBED" && r()));

  const stop = Date.now() + durationMs;
  while (Date.now() < stop) {
    await pubCh.send({
      type: "broadcast",
      event: "ping",
      payload: { t: Date.now() },
    });
    published++;
    await new Promise((r) => setTimeout(r, publishEvery));
  }

  await new Promise((r) => setTimeout(r, 2000)); // let final messages land

  console.log("\n──────── results ────────");
  console.log(`subscribers established : ${established}`);
  console.log(`subscribers refused     : ${refused}`);
  console.log(`messages published      : ${published}`);
  console.log(`messages received       : ${received} (expected ~${published * established})`);
  console.log(`fan-out latency p50     : ${pct(latencies, 50)} ms`);
  console.log(`fan-out latency p95     : ${pct(latencies, 95)} ms`);
  console.log(`fan-out latency p99     : ${pct(latencies, 99)} ms`);
  console.log("─────────────────────────");

  for (const c of subClients) await c.removeAllChannels();
  process.exit(0);
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
