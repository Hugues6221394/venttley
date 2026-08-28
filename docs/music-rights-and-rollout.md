# Music rights, rollout, and operations

Music on Vents and Stories is optional enrichment. A Vent must remain readable,
publishable, and removable when the catalog or audio player is unavailable.
This document is an operational gate, not a claim that Venttly owns a general
commercial music license.

## Catalog admission

Production may expose a track only when its `music_tracks` row records:

- a supported provider class and immutable provider track ID;
- title, artist, bounded preview URL, and preview duration;
- license code, evidence URL, rights holder, expiry when applicable, and
  attribution for licenses that require it;
- allowed regions when the agreement is territorial; and
- `is_active = true` after legal and release-owner review.

The initial `venttly_original/afterglow-v1` preview is generated from source in
`tool/generate_afterglow.dart`; it contains no downloaded recording or copied
sample. The repository does not enable Spotify, Apple Music, YouTube, TikTok,
Instagram, Freesound, Jamendo, or any other third-party catalog. Adding a
provider requires written terms that cover Venttly's actual commercial use,
territories, preview delivery, caching, attribution, takedowns, and reporting.

Never add a commercial track by copying a public streaming URL. Never store a
whole third-party catalog or full commercial recording in PostgreSQL. Provider
adapters return metadata and authorized preview references only.

## Release sequence

1. Apply the database migration before shipping a client that calls the v4 post
   RPC. Leave `feature_flags.vent_music` disabled with `rollout_pct = 0`.
2. Verify the exact release artifact can play the bundled original preview on a
   low-end Android device and an iOS device, both online and offline.
3. Run database authorization tests as an author, another authenticated member,
   and anonymous caller. Run publish replay after losing the response at the
   network boundary.
4. Enable internal accounts, then 1%, 5%, 25%, and 100%. Hold each stage for at
   least one peak traffic window. The rollout bucket is deterministic per user.
5. Stop expansion when an SLO breaches its error budget. Do not compensate by
   weakening rights, ownership, RLS, duration, or rate-limit checks.

Emergency kill switch:

```sql
update public.feature_flags
   set enabled = false, rollout_pct = 0
 where flag_key = 'vent_music';
```

This hides catalog metadata and blocks new attachments. Existing Vents remain
readable. If a specific right expires or receives a takedown, set that track's
`is_active` to false; the feed will omit its music metadata without hiding the
Vent.

## Content-free user-outcome SLOs

Measure only bounded operational metadata. Never log Vent or Story bodies,
display names, usernames, emails, phone numbers, auth tokens, device IDs,
preview query text, or signed media URLs.

Initial release objectives:

- Vent/Story publish success: at least 99.9% over 28 days, whether or not an
  optional track succeeds.
- Authorized attachment success: at least 99.5% over 28 days while the feature
  is enabled.
- Catalog search availability: at least 99.9%; p95 server latency below 500 ms.
- User-initiated preview start: at least 99%; p95 below 1.5 seconds on supported
  networks.
- Feed render success for music-bearing posts: no worse than the non-music feed
  error rate by more than 0.05 percentage points.
- Unauthorized/inactive attachment acceptance: exactly zero.

Safe dimensions include app version, platform, provider class, flag cohort,
operation outcome, normalized error category, and latency bucket. Track IDs may
be used only in access-controlled rights/takedown audit records, not general
product analytics.

## Rollback and incident handling

Disable the flag first. Preserve post rows and attachment references so rollback
is non-destructive and auditable. Do not delete catalog or post records during
an incident. Quarantine a track with `is_active = false`, preserve rights
evidence, and record who approved the change and why in the release/incident
system.

After containment, verify that:

- new search and attachment calls return no disabled tracks;
- existing Vents and Stories still load without music;
- playback stops when leaving a Story or when the app backgrounds;
- retries do not create duplicate posts or inflate counters; and
- analytics, logs, crash reports, FCM, and traces contain no vulnerable content.
