# Two sessions, one repository

One session builds console pages; another reviews and deploys. They share a git
repository and must not share a working tree.

## Why not

Both sessions edit `admin/`. Without separation:

- **Deploys ship half-written work.** `vercel --prod` uploads the working
  directory, not a commit. A deploy fired while a page is mid-write ships that
  page.
- **Commits sweep up somebody else's files.** `git add -A admin` from either
  session stages everything, including the other's unfinished work, under a
  message describing neither.
- **Checks report on a moving target.** `check-routes` failed on `/staff`
  naming a route that did not exist; two minutes later it passed. Nothing was
  broken — the route had been added to `SECTION_ROLES` before `page.tsx` was
  written, and the check ran in between. A red build that goes green on its own
  is worse than a real failure: it teaches people to re-run rather than read.

## The arrangement

| Tree | Path | Branch | Purpose |
|---|---|---|---|
| main | `Venttly/` | feature branch | Building. Edit freely, commit when a change is coherent. |
| deploy | `Venttly-deploy/` | `deploy/console` | Review and deploy. Never edited directly; only ever `git merge` of committed work. |

The deploy tree is a `git worktree` — a second checkout of the same repository,
sharing its history and objects. Not a clone: a commit in either is immediately
visible to the other, with no remote in between.

Created with:

```
git worktree add ../Venttly-deploy -b deploy/console
cp admin/.vercel/project.json ../Venttly-deploy/admin/.vercel/project.json
(cd ../Venttly-deploy/admin && npm ci)
```

`.vercel/project.json` is copied rather than re-linked because it is gitignored
and holds only a project and organisation id — no credentials. `node_modules`
is per-tree and has to be installed once.

## Deploying

Always from the deploy tree. Only committed work exists there, which is the
whole point:

```
cd ../Venttly-deploy
git merge <feature-branch>          # or: git reset --hard <sha>
cd admin && npm run typecheck && npm run build
npx vercel --prod
```

If `vercel --prod` is run from the main tree, it ships whatever is on disk at
that instant. Do not.

## Review, before merging

The building session commits; this one checks. In order, because each step is
cheaper than the next and failures early make the later ones meaningless:

1. **`git diff --stat`** against the last reviewed commit. Anything touched
   outside the stated scope is the first question to ask.
2. **`npm run typecheck`** — types, plus the two authorization invariants:
   - `check-routes`: every dashboard route is declared in `SECTION_ROLES`. A
     route absent from that table is reachable by every staff role.
   - `check-service-role-gates`: `createAdminClient` gates itself and is the
     only route to an RLS-bypassing client.
3. **Read every new route for least privilege.** The checks prove a route is
   *declared*, not that its roles are *right*. A new page granted to
   `read_only_auditor` that can suspend an account passes both checks.
4. **Read every new Server Action** for: a required reason on destructive
   operations, an audit record in the same transaction as the mutation, and
   re-fetching the target under lock rather than trusting form fields. These
   are the rules in README.md's "Engineering rules for new admin work", and
   nothing enforces them mechanically.
5. **`npm run build`** — a production build catches what `tsc` does not.
6. **Deploy to staging and open the pages.** Staging points at
   `Venttly Staging`, seeded with six accounts and three tribes, so a
   destructive action there costs nothing.

## What the checks cannot tell you

Both are text-based and structural. They confirm a route is declared and that
service-role access goes through one gate. They cannot tell you the roles on
that route are appropriate, that a mutation is audited, or that a query reads
less than it could. That judgement is the review, and it is why this file
describes reading the code rather than only running the commands.
