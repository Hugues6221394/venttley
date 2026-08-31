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

**Hugging Face Spaces no longer works for this.** Docker and Gradio Spaces now
require a paid plan; only Static Spaces are free, and a Static Space cannot run
Python. Checked on the signup page, not assumed.

### Koyeb — the recommended path

Free tier, one Docker web service, 512MB RAM, **no sleep**, and normally no
credit card. It builds straight from this repository, so no image registry and
no tokens are involved.

1. Sign in at [koyeb.com](https://www.koyeb.com) with GitHub.
2. **Create Web Service → GitHub →** this repository.
3. Set:

   | Field | Value |
   |---|---|
   | Work directory | `services/nsfw-classifier` |
   | Builder | Dockerfile |
   | Dockerfile path | `Dockerfile` (relative to the work directory) |
   | Port | `8090` |
   | Instance | Free |
   | Health check path | `/health` |

4. Deploy, then confirm it is alive:

   ```bash
   curl https://<your-app>.koyeb.app/health
   # {"ok":true,"model_loaded":false}
   ```

The model loads on the first request. `POST /warm` loads it without sending an
image, which is worth doing once after each deploy.

### Others that work

- **Render** — free web service, no Dockerfile changes needed, but it sleeps
  after 15 minutes of inactivity.
- **Google Cloud Run** — a genuinely generous always-free tier, but it wants a
  billing account on file.
- **Fly.io** — works well, also wants a card now.

### Memory

The free tiers above give 512MB. This fits: the ONNX weights are 127kB and
onnxruntime is the bulk of the image, not the runtime. If a host reports an
out-of-memory kill, `OMP_NUM_THREADS=1` cuts onnxruntime's arena.

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
