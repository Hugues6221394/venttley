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
    return {"ok": True}


@app.post("/classify")
async def classify(file: UploadFile = File(...)) -> dict:
    data = await file.read()
    if len(data) < 32:
        raise HTTPException(status_code=400, detail="too_small")
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
        if name in BLOCKED and score >= 0.5:
            verdict = "blocked"
        elif name in SENSITIVE and score >= 0.5 and verdict != "blocked":
            verdict = "sensitive"
    return {"verdict": verdict, "labels": labels, "csam": False}
