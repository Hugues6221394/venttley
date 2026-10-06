# Where voice vents live, and what they cost

**Decision: stay on Supabase Storage for launch. Revisit at a measured
threshold, not a guess.**

## What was measured, not assumed

On production, and on a device:

| | |
|---|---|
| Encoding | AAC-LC, mono, 44.1 kHz |
| Average whisper | **36 seconds** |
| Longest allowed | 10 minutes |
| Size at 96 kbps | 441 kB for 36s *(measured through all eight voice filters)* |
| Size at 64 kbps | **297 kB** — 33% less |
| Size at 48 kbps | 225 kB — 49% less |
| All whisper audio today | 3.3 MB across 9 objects |

## The bill is egress, not storage

Supabase Pro includes 100 GB storage and 250 GB egress, then charges
**$0.021/GB/month** for storage and **$0.09/GB** for egress.

A whisper is written once and played many times, so the two diverge fast:

- 100 GB of storage, at 297 kB each, is about **340,000 whispers**. Storage is
  not going to be the problem for a long time.
- 250 GB of egress is about **840,000 plays per month**.

Projected, at 64 kbps:

| Monthly plays | Egress | Cost above the included 250 GB |
|---|---|---|
| 500,000 | 148 GB | **$0** |
| 1,000,000 | 297 GB | ~$4 |
| 5,000,000 | 1.5 TB | ~$110 |
| 15,000,000 | 4.4 TB | ~$385 |

At 96 kbps every one of those numbers is 48% higher. That is why the bitrate
change came first — it is the only lever that costs nothing and applies to
storage and egress at once.

## Why not move to R2 or B2 now

Cloudflare R2 charges **nothing for egress**, which is genuinely the right
long-run answer for audio. It is still the wrong move this week:

- **It adds a processor.** The Privacy Policy published on 1 October names
  every processor and the country it works in, and a material change forces
  every user to re-accept. Adding R2 means amending that document and pushing
  a fresh consent prompt at people who just saw one.
- **The saving today is zero.** Below 250 GB of egress Supabase costs nothing
  extra, so the migration buys nothing until traffic is real.
- **It is new code on the critical path.** Signed URLs, a second upload path,
  a migration of existing objects, and a new failure mode — days before
  submission, for a bill that is currently $0.

## What to do instead

1. **Done: 64 kbps.** A third off storage and egress, no audible difference
   for speech. 48 kbps was measured and works, but 64 leaves headroom for the
   pitch-shifting filters without anyone noticing.
2. **Watch egress, not storage.** The number that matters is monthly egress
   against the 250 GB included.
3. **Move when egress passes ~150 GB/month** — 60% of the allowance, roughly
   500,000 plays. That is far enough ahead to do the migration calmly, and
   late enough that it is worth doing.

Check it with:

```sql
select pg_size_pretty(sum((metadata->>'size')::bigint)) as stored,
       count(*) as objects
  from storage.objects
 where bucket_id in ('whispers-media', 'chat-media', 'tribe-chat-media');
```

Egress itself is on the Supabase dashboard under Usage; it is not queryable
from SQL.

## If Supabase Pro is not enough later

R2 at that point, for the egress alone. Budget roughly a week: upload path,
signed playback URLs, a backfill of existing objects, a privacy-policy
amendment naming Cloudflare R2 and its region, and a consent cycle.
