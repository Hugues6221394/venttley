# Phase 0 Production Reality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Venttly's Home Stories and profile media production-real by removing demo fallbacks, enforcing friend-scoped stories, and aligning Supabase storage/schema with the client.

**Architecture:** Stories continue to use `posts.is_whisper` as the 24h story primitive, but the app must only show real active stories from the current user and accepted friends. Profile photos remain optional and use Supabase Storage plus `users.profile_photo_*` columns. Client code may degrade gracefully when migrations are not yet applied, but production should be fixed at the database layer.

**Tech Stack:** Flutter, Riverpod, Supabase Postgres, Supabase Storage, RLS/RPC, existing Venttly repository/provider patterns.

---

### Task 1: Live Supabase Audit

**Files:**
- Read: `supabase/migrations/0037_premium_home_stories_profile_photos.sql`
- Read: `supabase/migrations/0038_premium_feed_media_and_stats.sql`
- Read: `lib/data/services/supabase_backend.dart`

- [ ] **Step 1: List Supabase projects**

Use the Supabase connector `_list_projects` and select the project whose API URL matches the app configuration in `admin/.env.local` or Flutter environment files.

- [ ] **Step 2: Check migration status**

Use `_list_migrations(project_id)` and verify whether migrations `0037` and `0038` are present on the live project.

- [ ] **Step 3: Inspect schema**

Run `_execute_sql` with:

```sql
select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'users'
  and column_name in ('profile_photo_path', 'profile_photo_url')
order by column_name;

select id, name, public
from storage.buckets
where id in ('profile-photos', 'chat-media', 'whisper-audio', 'tribe-avatars');

select proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and proname in ('set_user_profile_photo', 'clear_user_profile_photo', 'mark_story_viewed');
```

- [ ] **Step 4: Run advisors**

Use `_get_advisors` for `security` and `performance`. Record only issues introduced or directly affected by this phase.

### Task 2: Remove Production Story Fallbacks

**Files:**
- Modify: `lib/presentation/screens/feed/feed_screen.dart`
- Test: `test/home_discovery_test.dart`

- [ ] **Step 1: Write/adjust test expectation**

Ensure home discovery or feed story derivation does not convert normal feed posts into stories when no active whisper exists.

- [ ] **Step 2: Remove fallback mapping**

Replace:

```dart
final stories = discovery.activeStories.isNotEmpty
    ? discovery.activeStories
    : posts.take(4).map(VentStory.fromPost).toList();
```

with:

```dart
final stories = discovery.activeStories;
```

- [ ] **Step 3: Delete `_fallbackStories()`**

Remove the demo Aidan/Maya/Leo stories and make the stories rail render a real empty state when `stories.isEmpty`.

### Task 3: Friend-Scoped Stories in Client

**Files:**
- Modify: `lib/presentation/screens/feed/feed_screen.dart`
- Modify if needed: `lib/core/providers.dart`

- [ ] **Step 1: Load accepted friends**

Use `myFriendsProvider` in `FeedScreen`.

- [ ] **Step 2: Filter stories**

Allow a story when:

```dart
story.authorId == me?.userId || friendIds.contains(story.authorId)
```

Stories without an `authorId` must not be shown, except the current user's own real story where an author id exists.

- [ ] **Step 3: Empty state copy**

Show a compact rail empty state: "No friend stories yet" and "When friends post, they stay here for 24 hours."

### Task 4: Friend-Scoped Stories in Supabase

**Files:**
- Create migration if needed under: `supabase/migrations/`
- Modify: `lib/data/services/supabase_backend.dart`
- Modify: `lib/data/repositories/vently_repository.dart`
- Modify: `lib/core/providers.dart`

- [ ] **Step 1: Add RPC or view**

Create `public.friend_stories` or `public.friend_stories_for_me()` returning active `is_whisper` posts where:

```sql
p.author_id = auth.uid()
or exists (
  select 1
  from friendships f
  where f.status = 'accepted'
    and (
      (f.requester_id = auth.uid() and f.addressee_id = p.author_id)
      or
      (f.addressee_id = auth.uid() and f.requester_id = p.author_id)
    )
)
```

Use `to authenticated` grants, explicit RLS-compatible filters, and indexes already present on friendships/posts where possible.

- [ ] **Step 2: Use server-scoped story query**

Add a repository method that fetches friend stories from the RPC/view. The Home rail must prefer this source over broad feed discovery.

### Task 5: Profile Photo Storage & Friendly Errors

**Files:**
- Modify if needed: `supabase/migrations/0037_premium_home_stories_profile_photos.sql`
- Modify: `lib/data/services/supabase_backend.dart`
- Modify: `lib/presentation/screens/profile/profile_screen.dart`

- [ ] **Step 1: Ensure bucket and policies**

The migration must create `profile-photos` and allow authenticated users to upload only under their own user id folder.

- [ ] **Step 2: Friendly client errors**

Map storage bucket/schema errors to user-facing copy:

```text
Profile photo storage is still being prepared. Please try again shortly.
```

Raw `StorageException` and `PostgrestException` text must not be displayed in the UI.

### Task 6: Verification

**Files:**
- Test: `test/home_discovery_test.dart`
- Test: related provider/widget tests if available

- [ ] **Step 1: Static checks**

Run:

```bash
dart format --set-exit-if-changed lib test
flutter analyze
```

If Flutter/Dart crashes in this Codex environment, record the exact failure and run any available non-Flutter checks.

- [ ] **Step 2: Targeted tests**

Run:

```bash
flutter test test/home_discovery_test.dart
```

- [ ] **Step 3: Supabase verification**

Use `_execute_sql` to confirm columns, buckets, functions, and story visibility helpers exist.

