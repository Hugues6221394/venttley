# Venttly NSFW classifier

The free half of image moderation. `media-scan` sends an image here, this
answers `clean` / `sensitive` / `blocked`, and `media-scan` decides what that
means for the upload. Policy stays there; this only classifies.

## Why it is a separate service

Supabase Edge Functions run Deno, and a vision model does not run in Deno.
Pretending otherwise is how the whole feature ends up switched off — which is
where it was: `media-scan` was deployed but answering
`{"ok":false,"error":"media_scan_disabled"}`, so every image sat on "Checking
this image…" forever.

## The model

[NudeNet](https://pypi.org/project/nudenet/) 3.x, **MIT licensed**, so
commercial use is fine.

It detects specific exposed regions rather than returning one "is this porn"
number, which suits a three-state policy: genitals exposed is not the same
judgement as a bare midriff, and the graded verdict reflects that.

**Maintenance risk, stated plainly as the safety brief requires:** the last
release was July 2024 and the author says they are "busy with other stuff…
looking for interested maintainer". It is not abandoned, and by the author's
own assessment it is the best open-source option for this. But it is one
person, and it is worth revisiting if it goes quiet for another year. An
Apache-2.0 alternative exists (`Falconsai/nsfw_image_detection`, a ViT
classifier) if a swap is ever needed — the `/classify` contract is what
`media-scan` depends on, not the model behind it.

## Run it locally

```bash
docker compose up --build
curl -F file=@some.jpg http://localhost:8090/classify
```

## Host it for nothing

Any free tier that runs a container works — Hugging Face Spaces (Docker SDK),
Fly.io scaled to zero, or Render's free web service. Then:

```bash
supabase secrets set NSFW_CLASSIFIER_URL=https://<your-host>
supabase secrets set MEDIA_SCAN_ENABLED=true
supabase functions deploy media-scan
```

## About sleeping

Free tiers sleep, and a cold start can outlast the Edge Function's timeout.
The failure is safe but annoying — the image is quarantined as `sensitive`
instead of published. Two cheap mitigations, both already in place:

- the ONNX weights are baked into the image, so waking costs seconds rather
  than a download;
- `POST /warm` loads the model without sending an image, so a ten-minute cron
  ping keeps it responsive.

## Tuning

| Variable | Default | Meaning |
|---|---|---|
| `NSFW_BLOCK_AT` | `0.5` | Confidence at which an exposed-genitals detection blocks the upload |
| `NSFW_SENSITIVE_AT` | `0.5` | Confidence at which a lesser detection quarantines it |
| `NSFW_MAX_BYTES` | `12582912` | Reject larger bodies outright |

## What it will not do

It never answers `clean` when it is unsure — it fails with a 5xx instead.
`media-scan` treats an unusable answer as `sensitive` and quarantines, and
treats `clean` as publishable. Given those two failure modes, staying quiet is
the safe one.

CSAM detection is **not** this model's job and must not be inferred from it.
That check belongs to Sightengine in `media-scan`, gated behind
`SIGHTENGINE_CSAM`, and routes to the incident pipeline rather than a normal
delete.
