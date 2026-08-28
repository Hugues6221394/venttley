# Venttly modern social app readiness checklist

Venttly's promise is not "we have social features." The promise is:

> A person can express something emotionally real, get a meaningful response,
> stay protected, and trust that the app will work every time.

That makes reliability a product feature. For Venttly, reliability means every
core social action either succeeds quickly, recovers predictably, or fails kindly
without losing the user's content, safety, or trust.

## 1. Product diagnosis

Modern social apps win through a tight loop:

1. User opens Venttly.
2. User immediately sees fresh, relevant emotional content.
3. User posts, replies, reacts, joins a tribe, or sends a message.
4. Another human responds.
5. Venttly sends a valuable notification.
6. User returns and feels heard, not manipulated.

Everything outside that loop is secondary until the loop is measured and healthy.

For Venttly, the primary risks are:

- Cold start: a new user opens the app and does not know where to belong.
- Empty response: a user vents and nobody replies.
- Safety failure: anonymous expression turns into harassment, spam, grooming, or
  self-harm mishandling.
- Trust failure: posts, comments, chat messages, notifications, or moderation
  actions behave inconsistently.
- Performance failure: the app looks premium but feels slow.
- Observability failure: the team cannot explain why retention, latency, or
  safety quality changed.

## 2. Current repo signals

The codebase already has strong social-app foundations:

- Flutter client with Supabase/Postgres backend and RLS.
- Anonymous/social identity, tribes, feed, questions, inbox, whispers, comments,
  reactions, stories, friends, and profiles.
- Text moderation, report/block flows, crisis support, media safety, CSAM
  pipeline, safety queues, admin/keeper moderation, and anti-spam migrations.
- Analytics events, PostHog-compatible tracking, Sentry integration, PII
  scrubbing, feature flags, search, push-token tables, notification engine, and
  realtime/presence migrations.
- Existing docs for architecture, notifications, and realtime load testing.

Main gaps to verify before calling it modern-production-ready:

- Push notifications are documented but still need real FCM/APNs client wiring
  and deployed fan-out.
- SLOs exist in spirit, but need dashboards, alerts, error budgets, and release
  gates.
- Automated test coverage looks narrow relative to the size of the product;
  add integration, RLS, moderation, realtime, notification, and failure-mode
  tests.
- Realtime/load-test docs exist; confirm executable scripts, staging data, and
  recorded baselines.
- The app needs explicit product-health reviews: retention, safety, reliability,
  and notification quality every week.

### Reliability and safety baseline implemented (2026-07-14)

- [x] Composer drafts and retry payloads are encrypted with platform secure
  storage, account-scoped, and migrated away from plaintext preferences.
- [x] Posts, audio Whispers, comments, whisper comments, DMs, and tribe messages use one
  mutation UUID across the first request and every retry.
- [x] Private server receipts and transaction locks make lost-response retries
  return the original resource instead of creating duplicates.
- [x] Automatic retries use bounded backoff; writes that exhaust the retry
  window remain visible and can be retried instead of being deleted.
- [x] The advisory moderation API is authenticated, size-bounded, and
  rate-limited; authoritative content rules execute at database ingress.
- [x] PII scrubbing covers nested telemetry, logs, breadcrumbs, exceptions,
  tokens, email addresses, phone-like values, and long free-form text.
- [x] New search/feature-flag surfaces use caller RLS and explicit Data API
  privileges; internal helpers and operational tables are not public RPCs.
- [x] CI now checks production-readiness file formatting, Flutter
  analysis/tests, admin type safety, a zero-state migration replay, and
  database linting.

These controls are implemented in source, not deployed. Staging migration
replay, RLS adversarial tests, Edge Function typechecking, and staging smoke
tests remain release gates.

### Staging-proof layer implemented (2026-07-15)

- [x] Transactional pgTAP contracts cover private receipt privileges, RPC
  grants, invoker views, DM isolation, author spoofing, idempotent replay,
  mutation-key misuse, active-room enforcement, and account scoping.
- [x] The moderation handler is dependency-injected and tested without network
  calls for auth, quotas, malformed/oversized input, cache hits, cache writes,
  provider degradation, and provider-output sanitization.
- [x] Pending image and voice bytes are encrypted in app-private local recovery
  storage before upload. Supabase Storage objects are not client-side E2EE.
  Upload and row-send retries retain local bytes until confirmation or explicit
  failed-send removal.
- [x] Vents, stories, replies, DMs, and tribe image/voice messages share the
  same durable media/outbox path and server mutation key.
- [x] DM voice-note schema, storage MIME types, room status, participant checks,
  media pairing/prefix validation, and private-post attachment checks now agree.
- [x] CI runs zero-state migration replay, pgTAP, schema lint, Flutter tests,
  admin typechecking, and Edge Function format/type/test gates.
- [x] A protected manual workflow validates locally first and refuses staging
  refs that are missing, ambiguously labelled, or equal to production.

These controls are implemented and locally tested where the workstation has a
runtime. The database suite still requires the CI Docker runner or an isolated
staging project; no remote project has been changed.

## 3. North-star metrics

Track these from day one and review them weekly.

- Activation: percent of new users who complete onboarding and perform one
  meaningful action in the first session.
- First response: percent of first posts that receive a reply or reaction within
  10 minutes, 1 hour, and 24 hours.
- Retention: D1, D7, D30 retention by acquisition source, age tier, and first
  action.
- Social depth: replies per post, reactions per post, conversations started,
  tribe joins, repeat comments, and saved/shared content.
- Safety quality: reports per 1k actions, confirmed-violation rate, median time
  to first moderation action, repeat-abuser rate, false-positive appeals.
- Reliability: crash-free sessions, core action success rate, p95/p99 latency,
  realtime fan-out latency, push delivery latency, failed background jobs.
- Notification trust: opt-in rate, tap-through rate, mute/unsubscribe rate,
  notification-caused opens that lead to reply/reaction.

## 4. Reliability SLOs

Use these as launch targets. Adjust only after real user data proves they are too
strict or too loose.

| User promise | Suggested SLO |
| --- | --- |
| App opens to usable home | p95 < 2.0s cached, p95 < 3.5s cold |
| Feed first page loads | p95 < 1.0s warm, p99 < 2.5s |
| Feed refresh succeeds | success rate >= 99.5% |
| Create post/comment | optimistic UI < 200ms, server commit p95 < 1.5s |
| Send DM/tribe message | local echo < 200ms, recipient fan-out p95 < 1.0s |
| Reaction/save/block/report | success rate >= 99.7%, idempotent retries |
| Notification route opens target | success rate >= 99% |
| Crash-free sessions | >= 99.8% before public launch |
| Moderation report first action | p95 < 24h; urgent/crisis paths immediate |
| Account deletion/export | completes or queues with visible status |

Error-budget rule: if a core SLO is breached for a release window, freeze
non-critical feature work until the cause is understood and the fix is shipped.

## 5. Core launch checklist

### A. First-session retention

- [ ] Onboarding asks for only what is needed to personalize and protect the
  user.
- [ ] A new user sees 5-10 high-quality posts/tribes immediately.
- [ ] The app prompts one low-friction action within 30 seconds: react, follow a
  tribe, answer a question, or post a short vent.
- [x] The first post flow has draft persistence and never loses text on network
  failure.
- [ ] Empty states suggest a useful next action, not generic explanation.
- [ ] New users can understand anonymous identity, safety rules, and community
  tone without reading a wall of policy text.

### B. Social loop

- [ ] Posting, replying, reacting, sharing, saving, and messaging all emit typed
  analytics events.
- [ ] Every interaction that can bring a user back creates a notification, but
  repeated events are grouped.
- [ ] The notification screen clearly separates replies, reactions, friend
  requests, moderation actions, and system updates.
- [ ] Deep links from notifications always land on the exact post, comment,
  chat, tribe, or moderation action.
- [ ] Feed ranking balances freshness, relevance, safety, and creator diversity.
- [ ] No fake activity, fake users, or simulated messages are used to inflate
  engagement.

### C. Trust and safety

- [ ] Report and block are reachable from every user-generated surface: posts,
  comments, whispers, DMs, tribe chat, profiles, and media.
- [ ] Block behavior is complete: hidden content, blocked DMs, no friend
  requests, no notification leaks, no profile stalking loop.
- [ ] Rate limits run server-side and cover all write paths, not only the client.
- [ ] Moderation decisions are logged with actor, reason, target, action, and
  timestamp.
- [ ] Keepers/admins have a queue sorted by severity and age.
- [ ] Crisis/self-harm content shows support without shaming the user or
  automatically punishing disclosure.
- [ ] Under-13 access is blocked where required; minors receive stricter DM,
  link, media, and discovery protections.
- [ ] CSAM and severe abuse paths preserve evidence according to policy and
  prevent account purges while incidents are open.
- [ ] Appeals or review paths exist for enforcement actions that affect accounts
  or content visibility.

### D. Reliability engineering

- [ ] Define SLIs for every core action: availability, latency, correctness, and
  durability.
- [ ] Create dashboards for feed, compose, comments, chat, notifications,
  moderation, auth, storage, and edge functions.
- [ ] Alerts page the team only for user-impacting failures, not noisy internals.
- [x] Core queued writes use idempotency keys where response loss/retries can
  duplicate posts, comments, DMs, or tribe messages.
- [x] Outbox/retry behavior covers posts, stories, comments, DMs, tribe text,
  image, and voice sends. Reactions remain idempotent set/toggle operations.
- [ ] All long-running jobs are safe to retry and have dead-letter visibility.
- [ ] Realtime connections are load-tested in staging at expected launch spikes.
- [ ] Database policies and indexes are tested with realistic row counts.
- [ ] Every release has a rollback path for client flags, migrations, and edge
  functions.

### E. Performance and mobile quality

- [ ] Profile feed, chat, compose, tribe detail, and notifications on low-end
  Android and older iPhones.
- [ ] Maintain 60 fps on common scroll paths; no large widget-tree rebuilds on
  feed updates.
- [ ] Images/audio use caching, placeholders, retry states, and size limits.
- [ ] Animations are 150-300ms and never block core interaction.
- [ ] Skeleton/loading states appear quickly and do not shift layout.
- [ ] Offline/poor-network states are visible, calm, and actionable.
- [ ] App startup, memory, battery, and network usage are measured per release.

### F. Data, privacy, and security

- [x] No service-role secrets or private moderation API keys ship in the client.
- [ ] RLS policies are tested for anonymous, authenticated, blocked, minor,
  keeper, moderator, admin, and auditor roles.
- [x] PII scrubber covers analytics, logs, breadcrumbs, errors, and event props.
- [ ] No vent body, DM plaintext, recovery phrase, email, IP, or precise location
  leaves the platform unintentionally.
- [ ] Data export, deletion, account purge, and legal-hold behavior are tested.
- [ ] Mobile security review covers storage, crypto, auth, network, platform API
  usage, code quality, anti-tamper needs, and privacy.
- [ ] Third-party SDKs are reviewed for data collection, consent, and store
  disclosures.

### G. Notifications

- [ ] Push opt-in request happens after the user receives obvious value.
- [ ] Push tokens register/unregister reliably across reinstall, logout, and
  token refresh.
- [ ] Muted rooms/tribes never send push.
- [ ] Notification copy is specific and human: replies, reactions, mentions,
  friend requests, moderation actions.
- [ ] No generic daily spam.
- [ ] Frequency caps exist per user and per event class.
- [ ] Push delivery and tap-to-target success are tracked.

### H. Store and compliance readiness

- [ ] Community guidelines, terms, privacy policy, and support contact are
  published and reachable in app.
- [ ] Apple/Google review accounts or demo mode are ready.
- [ ] Backend services are live during review.
- [ ] Content-rating questionnaires match actual UGC, anonymous chat, media,
  moderation, and minor protections.
- [ ] App metadata accurately describes anonymous social expression and safety
  practices.
- [ ] App review notes explain moderation, reporting, blocking, crisis resources,
  and demo credentials.

## 6. Testing checklist

- [x] Unit tests for moderation classification, PII scrubbing, ranking helpers,
  notification routing, user-friendly errors, and idempotency helpers.
- [ ] Widget tests for onboarding, compose, feed cards, report/block sheets,
  chat, empty/error states, and offline banners.
- [ ] Integration tests for signup, first post, reply, reaction, report, block,
  DM request, push tap, and account deletion.
- [x] SQL tests cover the highest-risk member/outsider DM, post-author,
  operational-table, invoker-view, and idempotency boundaries. Additional
  minor/staff/auditor role matrices remain.
- [ ] Load tests for feed read, comment write, chat fan-out, notification fan-out,
  media upload, and moderation queue.
- [ ] Chaos tests: Supabase slow/down, PostHog down, Sentry down, FCM down,
  moderation provider down, storage upload fails mid-flight.
- [ ] Regression tests for abuse paths: duplicate posts, mention spam, link spam,
  new-account spam, blocked-user interactions, and report floods.

## 7. Weekly operating rhythm

- Monday reliability review: SLO breaches, crash-free sessions, latency,
  background-job failures, incident follow-ups.
- Tuesday retention review: activation, first response, D1/D7 cohorts, funnel
  drops, notification quality.
- Wednesday safety review: open reports, severe incidents, false positives,
  blocked users, moderator response time.
- Thursday product-quality review: top UX friction, slow screens, confusing copy,
  support tickets.
- Friday release review: what ships, what is behind flags, rollback plan, known
  risks.

## 8. Next 30-day priority plan

Week 1: reliability baseline.
- [ ] Turn the SLO table into dashboards and alerts.
- [ ] Confirm Sentry/PostHog/Supabase event parity for core actions.
- [x] Add integration/RLS tests for the most dangerous write and DM paths.

Week 2: push and return loop.
- [ ] Finish FCM/APNs client wiring.
- [ ] Deploy notification fan-out in staging.
- [ ] Validate tap-to-target routing for every notification type.

Week 3: safety operations.
- [ ] Run report/block/moderation drills with seeded bad content.
- [ ] Measure time to first action and false-positive rate.
- [ ] Verify minor, crisis, CSAM, and legal-hold behavior.

Week 4: scale and failure drills.
- [ ] Run realtime and RPC load tests on staging.
- [ ] Simulate provider outages and poor networks.
- [ ] Fix the highest-impact failure mode before adding major features.

## 9. Reference anchors

- Apple App Review Guidelines, especially user-generated content, safety,
  performance, support contact, and data security:
  https://developer.apple.com/app-store/review/guidelines/
- Google Play User Generated Content policy:
  https://support.google.com/googleplay/android-developer/answer/9876937
- Google SRE Workbook on SLOs and error budgets:
  https://sre.google/workbook/implementing-slos/
- OWASP Mobile Application Security Verification Standard:
  https://mas.owasp.org/MASVS/
