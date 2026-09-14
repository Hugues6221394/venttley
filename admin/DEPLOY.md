# Deploying the console to admin.venttly.com

Vercel (Frankfurt) behind Cloudflare, with Cloudflare Access as the front door.

Why this shape, briefly. The app is Next 16.3 using `proxy.ts`, Server Actions
and 25 server-rendered routes, so Vercel is the reference platform and the
lowest-risk one weeks before a launch. Cloudflare keeps DNS and, more
importantly, puts an identity gate in front of the hostname — so a bug in this
app's own authorization cannot expose the console to the internet. That is not
hypothetical: the dashboard layout was relied on as the authorization gate for
months, and Next's own documentation says a layout cannot stop the pages
beneath it from rendering. Edge identity is the control that survives mistakes
like that.

**Order matters.** Steps 5 and 6 can lock you out of the console if done before
step 7 confirms they work. Do them in this order.

---

## 1. Upstash first — it is a hard dependency

Create a Redis database at <https://console.upstash.com>, region **eu-central-1
(Frankfurt)**, to sit beside Supabase.

Not optional. `lib/redis.ts` fails closed in production: with these unset,
login and audit export refuse outright. A deploy without them is not a console
with weaker rate limiting, it is a console nobody can sign in to.

Keep `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`.

## 2. Vercel project

From `admin/`:

```
npx vercel link          # create/link the project — run from admin/, not the repo root
npx vercel env add ...   # or paste them in the dashboard
```

`vercel.json` already pins `regions: ["fra1"]` and disables preview
deployments. Both are deliberate — see the comments there.

Set every variable at **Production scope only**. Preview scope would put the
service-role key, which bypasses RLS on every table, on a URL with none of the
edge controls in front of it.

| Variable | Value |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | the production project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | anon/publishable key |
| `SUPABASE_SERVICE_ROLE_KEY` | service role key — never `NEXT_PUBLIC_` |
| `UPSTASH_REDIS_REST_URL` | from step 1 |
| `UPSTASH_REDIS_REST_TOKEN` | from step 1 |
| `ADMIN_REQUIRE_MFA` | `true` |
| `ADMIN_ORIGIN_SECRET` | leave unset until step 6 |
| `ADMIN_IP_ALLOWLIST` | leave unset; Access (step 5) is the stronger control |

## 3. Deploy

```
npx vercel --prod
```

Confirm the `*.vercel.app` URL loads the login page. It is still open to the
internet at this point — steps 5 and 6 are what close it.

## 4. DNS

Cloudflare → venttly.com → DNS → add `admin` as a CNAME to the Vercel target,
**proxied** (orange cloud). Grey cloud would bypass everything below.

Add `admin.venttly.com` as a domain on the Vercel project so its certificate is
issued.

## 5. Cloudflare Access — the front door

Zero Trust → Access → Applications → Add a self-hosted application.

- Domain: `admin.venttly.com`
- Session duration: 8 hours or less
- Policy: Allow, matched on the specific staff email addresses. Not a domain
  rule — `@venttly.com` would admit every future mailbox, including ones
  created by someone who has taken over the mail tenant.
- Require an identity provider with MFA, or Access's one-time PIN as a floor.

Free up to 50 users.

This is the highest-value control in this document. It authenticates before a
request reaches the app, so it holds even if the app's own checks are wrong.

## 6. Lock the origin

Without this, anyone who finds the `*.vercel.app` hostname skips Access, the
WAF and the IP allowlist in one step — and origin hostnames are not secret,
they appear in certificate transparency logs.

Generate a secret:

```
openssl rand -hex 32
```

Cloudflare → Rules → Transform Rules → Modify Request Header → Add:

- If: hostname equals `admin.venttly.com`
- Set static header `x-venttly-origin` to the secret

Then set `ADMIN_ORIGIN_SECRET` to the same value in Vercel and redeploy.
`proxy.ts` answers 404 — not 403 — to anything arriving without it, so probing
the origin reveals nothing about whether something is there.

Verify before relying on it:

```
curl -sS -o /dev/null -w '%{http_code}\n' https://<project>.vercel.app/login
# expect 404

curl -sS -o /dev/null -w '%{http_code}\n' https://admin.venttly.com/login
# expect 200, or a redirect to the Access login
```

If the first returns 200, the Transform Rule is not matching and the origin is
still open.

## 7. Confirm, in the console

Sign in and open **/system → Environment**. Four rows have to read green:

- Service role key — configured
- Upstash Redis — configured, and *Rate limiting — enforced* (they are
  different statements; the second is the one that matters)
- Origin locked to Cloudflare — enforced
- MFA required — required

Anything amber there is a control you believe you have and do not.

## 8. Only then, the IP allowlist

`ADMIN_IP_ALLOWLIST` is read from `CF-Connecting-IP`, which Cloudflare
overwrites and a caller cannot forge — but only while step 6 holds. Set it
after step 7 confirms the origin is locked, never before, or the allowlist is
checking a header anyone can write.

Set it to your office or VPN egress ranges. With Access already in place this
is defence in depth rather than the primary gate; skipping it is defensible,
setting it wrong locks you out.

---

## Staging, and developing against a deployment

Preview deployments are disabled in `vercel.json` on purpose: every preview
would need the service-role key to function at all, on a URL outside every
control above.

The safe version of the same idea is a second Supabase project as a staging
database — there is already one in the account (`Hugues6221394's Project`,
eu-central-1, currently paused) — with a separate Vercel project pointed at it
and its own Access policy. Preview URLs then carry a staging key, and a mistake
costs test data instead of the audit log.

## What this does not cover

From the checklist in README.md, still outstanding and not made true by
deploying:

- Migrations applied to an isolated staging project and pgTAP run there
  (production has been rebuilt from the chain and verified, which is not the
  same thing)
- Role/route/RPC combinations tested adversarially — forged Server Action
  payloads, expired sessions, removed roles, AAL1 sessions
- Audit durability, incident paging, rollback and restore rehearsed

None of these block a deploy behind Access. All of them block treating the
console as production-grade for on-call use.
