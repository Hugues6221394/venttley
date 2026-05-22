# Venttly Admin

Desktop-first SaaS dashboard for the Venttly app owner. Reads/writes the same
Supabase project as the mobile app.

## Stack

- **Next.js 15** (App Router, React Server Components)
- **Tailwind CSS** — brand palette mirrors `lib/presentation/theme/colors.dart`
- **@supabase/ssr** — cookie-based auth that survives SSR
- **TypeScript**

## Setup

```bash
cd admin
npm install
cp .env.local.example .env.local
# Fill in NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY,
# and SUPABASE_SERVICE_ROLE_KEY.
npm run dev
```

Visit http://localhost:3000.

## Auth

- The login page calls `signInWithPassword` with the synthetic email
  (`<username>@id.venttly.app`) — the same handle the mobile app uses.
- The dashboard layout server-checks `users.user_role == 'super_admin'`
  every request. Anyone else lands on a "Not authorized" panel.

## What's wired

| Page | Backing data |
| --- | --- |
| Overview | Real counts: users / tribes / posts / comments / reports / chat msgs + 7d growth, 24h post volume |
| Moderation | Real `reports` queue with mark-resolved + soft-delete-post server actions |
| Users | Paged user table, pseudonym + status filter, suspend / reactivate |
| Tribes | Real tribe table, category + flag filters, feature / suspend toggles |
| Analytics | 30-day new-user series, sentiment trend, top categories, top tribes |
| Notifications | Compose platform-wide announcement → fans out into `notifications` + audit row in `admin_broadcasts` |
| Settings | Env-var presence, moderation pipeline summary, role assignment (normal / plug / super_admin) |

## Architecture notes

- `lib/supabase/server.ts` returns the Supabase client used by Server
  Components. It uses the **service role key**, so it bypasses RLS for admin
  reads. Never import it from a client component.
- `lib/supabase/client.ts` returns the browser client used by the login form
  and any future client-side mutations.
- Pages live under `app/(dashboard)/<name>/page.tsx`. The route group
  `(dashboard)` shares one layout with the sidebar shell.
