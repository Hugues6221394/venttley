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

## What's live in this MVP

| Page | Status |
| --- | --- |
| Overview | Real counts: users, tribes, posts, comments, reports, growth window |
| Moderation | Real `reports` queue with mark-resolved + soft-delete-post actions |
| Users | Real user list with role + safety tier filters and per-row actions |
| Tribes | Coming soon |
| Analytics | Coming soon |
| Notifications | Coming soon |
| Settings | Coming soon |

## Architecture notes

- `lib/supabase/server.ts` returns the Supabase client used by Server
  Components. It uses the **service role key**, so it bypasses RLS for admin
  reads. Never import it from a client component.
- `lib/supabase/client.ts` returns the browser client used by the login form
  and any future client-side mutations.
- Pages live under `app/(dashboard)/<name>/page.tsx`. The route group
  `(dashboard)` shares one layout with the sidebar shell.
