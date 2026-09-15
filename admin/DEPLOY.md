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

Not optional. `lib/redis.ts` fails closed in production: with these unset,
login and audit export refuse outright. A deploy without them is not a console
with weaker rate limiting, it is a console nobody can sign in to.

**One database per environment.** Sharing means staging logins spend
production's budget against the same keys — the limiters are keyed on IP and
user id, and the prefixes (`login`, `audit_export`, …) are fixed in code, so
two environments pointed at one database are counting the same counters.
Because the limiter fails closed, the failure mode is operators locked out of
the live console by test traffic.

Create at <https://console.upstash.com> → **Create Database**:

| Field | Value | Why |
|---|---|---|
| Name | `venttly-admin-prod` / `venttly-admin-staging` | Match the Vercel project names; three systems with three naming schemes is how the wrong key reaches the wrong place |
| Primary region | **eu-central-1 (Frankfurt)** | Supabase is `eu-central-1` and Vercel is `fra1`. Every limited request pays a round trip here |
| Type | **Regional** | Global replicates worldwide and costs more. A handful of operators in one region |
| Eviction | **Enabled** | See below |
| TLS | on (default) | |

Eviction is the counterintuitive one. Normally you would leave it off for data
you care about; here it is the opposite. If the database fills with eviction
off, writes fail, the limiter errors, and because it fails closed *nobody can
sign in*. With eviction on, stale rate-limit counters are dropped instead and
login keeps working. These are throwaway counters — losing one resets somebody's
attempt count and nothing else.

Then copy `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN` from the
database's **REST API** section (there is usually a `.env` tab with both).

### Which database belongs to which environment

| Environment | Supabase project | Vercel project | Upstash |
|---|---|---|---|
| staging | `rbtvilckwihzdpqgjvmz` | `venttly-admin-staging` | `vast-tadpole-78776` |
| production | `gyeibgaqrmnepbnfbtzc` | `venttly-admin-prod` | *(the new one)* |

`setup-vercel.sh` fetches the Supabase keys itself from the project ref for the
environment named on the command line, so those two columns cannot be crossed
by a paste slip. Upstash is typed in by hand and is the one that can.

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

The safe version of the same idea already exists.

**`Venttly Staging`** — project ref `rbtvilckwihzdpqgjvmz`, eu-central-1, free
tier. The full migration chain applied to it from empty in one pass, and the
pgTAP suite passes against it: 790 assertions, zero failures. That is the
staging run README.md asks for under "Before deploying", and it had never been
done — production was rebuilt from the chain, which proves the chain replays,
not that it applies forward to a new database.

Seeded with `supabase/seed/test_accounts.sql`: six accounts including
`tester_admin` (super_admin) and `tester_keeper` (plug), three tribes. Password
for all of them is in that file — they are development accounts and must never
exist on production.

Set it up as its own Vercel project:

```
npx vercel link                       # create a SEPARATE project, e.g. venttly-admin-staging
./scripts/setup-vercel.sh staging
npx vercel --prod
```

It needs its **own** Upstash database. Sharing one with production means
staging logins spend production's rate-limit budget against the same keys, and
the limiter fails closed — so the failure mode is operators locked out of the
real console by test traffic.

Give it its own Cloudflare Access policy too. `staging-admin.venttly.com` with
the same allow-list is fine; what matters is that it is not open, because it
holds a service-role key for a database that will accumulate realistic-looking
test data.

The database password generated when the project was created is at
`~/venttly-staging-db-password.txt` (mode 600, outside the repo). Move it to a
password manager and delete the file.

Connect to it directly with the session pooler — the free tier has no IPv4
address for `db.<ref>.supabase.co`, so a direct connection fails to resolve:

```
postgresql://postgres.rbtvilckwihzdpqgjvmz:<password>@aws-0-eu-central-1.pooler.supabase.com:5432/postgres
```

Push migrations to it with `--db-url` rather than `supabase link`, which would
repoint the repo at staging and leave the next `db push` aimed at the wrong
database:

```
supabase db push --db-url "<the pooler url above>"
```

## What this does not cover

From the checklist in README.md, still outstanding and not made true by
deploying (the staging pgTAP run is now done — see above):

- Role/route/RPC combinations tested adversarially — forged Server Action
  payloads, expired sessions, removed roles, AAL1 sessions
- Audit durability, incident paging, rollback and restore rehearsed

None of these block a deploy behind Access. All of them block treating the
console as production-grade for on-call use.
