"""Local ONNX NSFW sidecar. media-scan calls /classify with the image bytes.

CSAM is not this model's job — Sightengine still owns that check. A hit
here only produces clean | sensitive | blocked.
"""

from __future__ import annotations

import os
import tempfile

from fastapi import FastAPI, File, HTTPException, UploadFile

app = FastAPI(title="venttly-nsfw-classifier")
_detector = None

# An upload bigger than this is refused before it reaches the model. media-scan
# already caps what it sends, but this service is reachable on its own and a
# 200MB body should not be able to take down moderation for everybody.
MAX_BYTES = int(os.environ.get("NSFW_MAX_BYTES", str(12 * 1024 * 1024)))

# Detection thresholds as configuration rather than literals, so the line can
# be moved without a redeploy.
BLOCK_AT = float(os.environ.get("NSFW_BLOCK_AT", "0.5"))
SENSITIVE_AT = float(os.environ.get("NSFW_SENSITIVE_AT", "0.5"))

BLOCKED = {
    "FEMALE_GENITALIA_EXPOSED",
    "MALE_GENITALIA_EXPOSED",
    "ANUS_EXPOSED",
}
SENSITIVE = {
    "FEMALE_BREAST_EXPOSED",
    "BUTTOCKS_EXPOSED",
    "FEMALE_GENITALIA_COVERED",
    "MALE_GENITALIA_COVERED",
    "ANUS_COVERED",
}


def detector():
    global _detector
    if _detector is None:
        from nudenet import NudeDetector

        _detector = NudeDetector()
    return _detector


@app.get("/health")
def health() -> dict[str, bool]:
    return {"ok": True, "model_loaded": _detector is not None}


@app.post("/warm")
def warm() -> dict[str, bool]:
    """Load the model without classifying anything.

    Free hosting tiers sleep. A cold start can outlast media-scan's timeout,
    and the consequence is safe but wrong: a perfectly ordinary photo gets
    quarantined because the classifier was still waking up. A scheduled ping
    here avoids that.
    """
    detector()
    return {"ok": True, "model_loaded": True}


@app.post("/classify")
async def classify(file: UploadFile = File(...)) -> dict:
    data = await file.read()
    if len(data) < 32:
        raise HTTPException(status_code=400, detail="too_small")
    if len(data) > MAX_BYTES:
        raise HTTPException(status_code=413, detail="too_large")
    suffix = os.path.splitext(file.filename or "image.jpg")[1] or ".jpg"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=True) as tmp:
        tmp.write(data)
        tmp.flush()
        detections = detector().detect(tmp.name)

    labels: dict[str, float] = {}
    verdict = "clean"
    for item in detections or []:
        name = str(item.get("class") or item.get("label") or "")
        score = float(item.get("score") or 0)
        if not name:
            continue
        labels[name] = max(labels.get(name, 0.0), score)
        if name in BLOCKED and score >= BLOCK_AT:
            verdict = "blocked"
        elif name in SENSITIVE and score >= SENSITIVE_AT and verdict != "blocked":
            verdict = "sensitive"
    return {"verdict": verdict, "labels": labels, "csam": False}
