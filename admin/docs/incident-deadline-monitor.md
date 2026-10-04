# Incident deadline producer: monitoring and failure drill

Implementation is local/tested code, not provisioned external paging. No rollout
is enabled by migration `20261029090013_incident_deadline_health.sql`.

## Signals and boundaries

`staff_notification_monitor()` remains a read-only, service-role-only RPC. It
now includes `incident_deadlines`, independent of delivery-worker health:

- `enabled`: global inbox, incident coordination and incident notices all on.
- `scheduler_active`: the named deadline cron job is installed and active.
- `succeeded_at` / `worker_stale`: success in the last two minutes, with future
  clock skew over one minute rejected. A disabled or lock-skipped run never
  advances success. A role/source/global rollout change invalidates prior health.
- `enqueued`: actual inserts from the last successful pass, capped at 2,100.
- `oldest_unprocessed_due_at` / `backlog_overdue`: one extra eligible candidate
  detects remaining backlog past five minutes without counting all incidents.
  This is a snapshot, not a continuous backlog or an incident response SLA.
- `batch_max_lag_seconds`: maximum observed deadline-to-enqueue delay for the
  processed batch. Empty batches report null, not zero or an invented percentile.

The reconciler keeps the existing due-date index, shared advisory lock, current
pilot/recipient checks and durable deduplication keys. It selects at most 101
eligible candidates and processes 100 per pass. Selection may still examine
already-notified active incidents; production-shaped query plans remain a gate.
Success telemetry commits in the same transaction as the notices. An enqueue
failure rolls the whole batch back and remains a failed cron run; it is not
swallowed into a successful heartbeat. Cancellation/crash likewise cannot mark
success. Inspect native cron history for diagnosis, never forward raw SQL error
messages into notifications or analytics.

The probe contains no incident titles, notes, source IDs, staff IDs, credentials
or free-form errors. Authenticated staff cannot directly call this machine API
or read private runtime tables. Human access does not imply service credentials.

## Independent runner

On a separately operated server/monitor (not the delivery worker or database
cron job being monitored), inject these variables from its secret manager:

- `NOTIFICATION_MONITOR_URL`: trusted Supabase API origin, HTTPS except loopback.
- `NOTIFICATION_MONITOR_SERVICE_KEY`: server-only legacy service-role JWT key
  for this existing service-only RPC. Never use a `NEXT_PUBLIC_` variable, place
  this key in browser code, commit it, or pass it as a command-line argument.
  This key is highly privileged: restrict access to the monitor runtime and
  rotate it under the existing service-key procedure.

Run:

```sh
node scripts/monitor-notifications.mjs
```

The runner has an eight-second request deadline, refuses redirects and remote
plain HTTP, limits response bytes, validates the expected metadata, and emits
only fixed status/reason codes. It does not log the target, key or raw response.

| Exit | Status | Meaning |
| --- | --- | --- |
| 0 | healthy | All enabled, observed producers pass the probe checks |
| 1 | attention | Stale worker, inactive schedule, overdue backlog or failed delivery |
| 2 | unknown / disabled | Probe failed/malformed/stale, or rollout intentionally disabled |

Disabled is **not** healthy. Configure planned-pilot suppression explicitly in
the external monitor; never silently turn exit 2 into health. A missing monitor
run needs its own external watchdog. A delivery outage must not be paged only
through this same in-app notification system.

Recommended initial polling is once per minute with incident deduplication and
an independently routed alert. Thresholds above are operational defaults, not
an agreed SLO. A named owner, destination, cadence, escalation policy, secret
provisioning and a staging drill are required before enabling production. No
external service, schedule, alert delivery or on-call commitment was created.

## Local evidence and staging drill

- pgTAP `0076_incident_deadline_health.test.sql` exercises effective grants,
  no-op/unknown/future/stale health, a paused scheduler, 101 overdue incidents,
  capped batches, retry deduplication, real enqueue failure/atomic rollback,
  recovery and kill-switch invalidation. Its entire fixture rolls back.
- `check-notification-monitor.mjs` tests status classification, safe failures,
  invalid responses, transport configuration and oversized responses.
- The incident browser harness calls the probe through local HTTP using a
  server-only fixture credential, rejects its authenticated-human invocation,
  detects a missing producer heartbeat and a paused schedule, then restores
  disabled controls and the saved cron state.

In staging with synthetic data: pause only the deadline cron job, keep delivery
running, verify independently routed stale/schedule alerts, resume it, verify
deduplicated catch-up and recovery, then rehearse source/global rollback. Also
test network/database loss and monitor-process loss. Do not run fault injection
on production or use genuine vulnerable content as a fixture.
