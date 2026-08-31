#!/usr/bin/env bash
#
# Publish the classifier to a Hugging Face Space.
#
# Why Hugging Face: the free tier runs a Docker container, needs no card, and
# gives a stable HTTPS URL — which is the whole requirement. Fly and Render
# work too; Fly now wants a card, and Render's free tier sleeps harder.
#
# What you need first:
#   1. A Hugging Face account.
#   2. A WRITE access token: huggingface.co/settings/tokens
#   3. The Space created as SDK "Docker": huggingface.co/new-space
#
# Then:
#   HF_TOKEN=hf_xxx HF_SPACE=yourname/venttly-nsfw ./deploy-huggingface.sh
#
# The token is read from the environment and never written to disk here. Do not
# paste it into a file in this repository.

set -euo pipefail

: "${HF_TOKEN:?Set HF_TOKEN to a Hugging Face write token}"
: "${HF_SPACE:?Set HF_SPACE to <user>/<space-name>}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> Assembling the Space from $here"

# Spaces read configuration from README front matter. app_port must match what
# the Dockerfile exposes, or the Space builds and then answers nothing.
cat > "$work/README.md" <<'FRONTMATTER'
---
title: Venttly NSFW Classifier
emoji: 🛡️
colorFrom: pink
colorTo: purple
sdk: docker
app_port: 8090
pinned: false
---

# Venttly NSFW classifier

Image safety classification for Venttly. Called server-to-server by the
`media-scan` Supabase Edge Function; not a public demo.

`POST /classify` (multipart, field `file`) returns
`{"verdict": "clean|sensitive|blocked", "labels": {...}}`.

Model: NudeNet 3.x (MIT). This endpoint classifies only — the decision about
what a verdict means to an upload lives in `media-scan`.
FRONTMATTER

cp "$here/app.py" "$here/Dockerfile" "$here/requirements.txt" "$work/"

cd "$work"
git init -q
git checkout -q -b main
git add -A
git -c user.email=deploy@venttly.app -c user.name=venttly \
    commit -qm "Deploy Venttly NSFW classifier"

echo "==> Pushing to https://huggingface.co/spaces/$HF_SPACE"
# The token goes in the remote URL for this one push and dies with the temp dir.
git push -q --force "https://user:${HF_TOKEN}@huggingface.co/spaces/${HF_SPACE}" main

cat <<DONE

==> Pushed. The Space is building; first build takes a few minutes.

Watch it:      https://huggingface.co/spaces/${HF_SPACE}
Health check:  curl https://$(echo "$HF_SPACE" | tr '/' '-' | tr '[:upper:]' '[:lower:]').hf.space/health

When /health answers, point the Edge Function at it:

  supabase secrets set NSFW_CLASSIFIER_URL=https://$(echo "$HF_SPACE" | tr '/' '-' | tr '[:upper:]' '[:lower:]').hf.space
  supabase secrets set MEDIA_SCAN_ENABLED=true
  supabase functions deploy media-scan

DONE
