# Realtime & connection load test

Validates that Venttly's realtime (tribe presence + chat fan-out) and Postgres
connection layer hold up before launch. Run against **staging**, never prod.

> Why this matters: at scale the two classic Supabase walls are (1) **Realtime
> concurrent-connection limits** (plan-gated) and (2) **Postgres connection
> exhaustion** — both hit long before CPU does. This test finds them early.

---

## 0. Before you start — pooling & limits checklist

- [ ] **Supavisor (connection pooler) is ON.** Supabase dashboard → Database →
      Connection pooling. App/edge traffic should use the **transaction** pooler
      (port 6543 / the pooler URL), not a direct connection (5432). Confirm the
      client + edge functions use the pooled connection string.
- [ ] **`max_connections`** vs. pool size: check Database → Settings. Direct
      connections are scarce (Free ~60, Small ~90…); the pooler multiplexes them.
      Every long-lived direct connection is one you can't get back.
- [ ] **Realtime concurrent-connection limit for your plan.** Free ≈ 200, Pro
      ≈ 500 by default, higher tiers / add-ons scale it. **Millions of MAU does
      NOT mean millions of concurrent sockets**, but launch spikes will blow past
      200–500 fast. Know your ceiling before the test; raise it if needed.
- [ ] **Realtime messages/sec** quota for your plan (also gated).
- [ ] RLS on the realtime tables is efficient — a heavy RLS policy runs per
      change per subscriber and is a common fan-out bottleneck.
- [ ] You have a **staging** project with representative seed data (tribes with
      members, rooms). Never point this at production.

## 1. Targets / SLOs (tune to your launch plan)

| Metric | Target |
|---|---|
| Concurrent realtime connections held | ≥ your plan ceiling (verify the number) |
| Message fan-out latency (publish → all subscribers) p95 | < 1.0 s |
| Message fan-out latency p99 | < 2.5 s |
| RPC (send message / fetch feed) p95 | < 300 ms |
| RPC error rate under load | < 0.5% |
| DB pool saturation at target load | < 80% |

## 2. What to test

1. **Connection scale** — ramp concurrent realtime subscribers (100 → 500 →
   1k → 2k…) until connections start being refused. Record the ceiling.
2. **Fan-out latency** — with N subscribers on a tribe channel, publish
   messages at a steady rate; measure publish→receive latency percentiles.
3. **Write path under load** — concurrent `send_*_message` inserts (which also
   trip the 0088 velocity triggers — watch that the trigger `COUNT`s stay
   index-served via the 0090 indexes and don't spike write latency).
4. **DB pool** — while the above runs, fire concurrent read RPCs (feed, tribe
   messages) and watch the pooler's active/waiting connections.

## 3. How to run

Realtime (Node, `loadtest/realtime-load.mjs`):

```bash
cd loadtest
npm init -y && npm i @supabase/supabase-js
# STAGING creds only. The script refuses to run without STAGING_OK=1.
SUPABASE_URL="https://<staging-ref>.supabase.co" \
SUPABASE_ANON_KEY="<staging-anon-key>" \
CHANNEL="tribe:load-test" \
SUBSCRIBERS=500 \
DURATION_SEC=120 \
PUBLISH_EVERY_MS=1000 \
STAGING_OK=1 \
node realtime-load.mjs
```

It prints: connections established/refused, messages published, and fan-out
latency p50/p95/p99.

HTTP/RPC (k6 — optional, for the write/read path):

```bash
# Install k6 (https://k6.io). Then, with a staging user JWT:
SUPABASE_URL=... ANON_KEY=... USER_JWT=... k6 run loadtest/rpc-load.js
```

## 4. What to watch (dashboards)

- **Supabase → Reports → Realtime**: concurrent connections, messages/sec,
  channel counts. Watch for the connection ceiling and any dropped messages.
- **Database → Connection pooling**: active vs. waiting client connections. If
  `waiting` climbs, the pool is saturated → raise pool size or reduce direct
  connections.
- **Database → Query performance**: the velocity-trigger `count(*)` queries and
  the feed/message reads. Confirm index usage (`EXPLAIN`), not seq scans.
- **Logs**: `too many connections`, realtime `subscribe timeout`, RLS errors.

## 5. Interpreting results / likely fixes

- **Connections refused early** → you hit the plan's realtime ceiling. Raise the
  plan/add-on, or reduce per-client channels (one multiplexed channel per tribe,
  not per-message).
- **Fan-out p95 climbs with subscriber count** → RLS on the realtime table is
  too heavy, or too many channels. Simplify the policy; batch presence.
- **Pool `waiting` > 0 sustained** → connection exhaustion. Ensure everything
  uses the transaction pooler; increase pool size; move long queries off the
  request path.
- **Write latency spikes under load** → check the 0088 velocity triggers are
  index-served (0090); if not, the `COUNT` is seq-scanning.

## 6. Teardown

- Delete the `tribe:load-test` fixtures / test users from staging.
- Reset any temporarily-raised limits if you don't need them yet.
