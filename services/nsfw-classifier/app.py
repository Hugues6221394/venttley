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

# Thresholds as configuration rather than literals, so a line can be moved
# without a redeploy.
#
# BLOCK_AT is deliberately high. Blocking deletes somebody's post, and this
# model returns confidences, not certainties — a wrongly blocked holiday photo
# is a reason to leave an app, while a wrongly veiled one is a blur with an
# appeal behind it. So a block needs the model to be quite sure.
BLOCK_AT = float(os.environ.get("NSFW_BLOCK_AT", "0.75"))

# Below BLOCK_AT but above this, exposed nudity is veiled rather than refused —
# the band where the model thinks it saw something and might be wrong.
NUDITY_VEIL_AT = float(os.environ.get("NSFW_NUDITY_VEIL_AT", "0.40"))

# Clothed-but-suggestive detections only ever reach "sensitive".
SUGGESTIVE_AT = float(os.environ.get("NSFW_SUGGESTIVE_AT", "0.50"))

# Actual nudity — a body part that is exposed, not clothed. A high-confidence
# detection here refuses the upload outright.
NUDITY_EXPOSED = {
    "FEMALE_GENITALIA_EXPOSED",
    "MALE_GENITALIA_EXPOSED",
    "ANUS_EXPOSED",
    "FEMALE_BREAST_EXPOSED",
    "BUTTOCKS_EXPOSED",
}

# Suggestive but clothed. Veils for review and NEVER blocks: the difference
# between "covered" and "exposed" is the difference between a swimsuit photo and
# pornography, and deleting the former would be the worse mistake by far.
SUGGESTIVE = {
    "FEMALE_GENITALIA_COVERED",
    "MALE_GENITALIA_COVERED",
    "ANUS_COVERED",
}

# Everything else NudeNet reports — FACE_*, BELLY_EXPOSED, ARMPITS_EXPOSED,
# FEET_EXPOSED, FEMALE_BREAST_COVERED and the rest — is ordinary human anatomy
# in ordinary photographs and is deliberately absent from both sets. A person in
# a vest top is not a moderation event. FEMALE_BREAST_COVERED in particular
# fires at ~0.46 on a woman in a business suit, which is exactly why it is not
# here.

def detector():
    global _detector
    if _detector is None:
        from nudenet import NudeDetector

        _detector = NudeDetector()
    return _detector


def decide(detections) -> tuple[str, dict[str, float]]:
    """Turn raw detections into one verdict.

    Three outcomes, and the asymmetry between them is the whole design:

      blocked   — exposed nudity the model is confident about. The post is
                  refused and removed.
      sensitive — exposed nudity the model is unsure about, or something
                  clothed-but-suggestive. Veiled, still there, appealable.
      clean     — everything else.

    Blocking is the only destructive outcome, so it is the hardest to reach: it
    needs a label that means *exposed*, at BLOCK_AT or above. Anything less
    certain falls to sensitive rather than being deleted. A wrongly blocked
    holiday photo is a reason to leave an app; a wrongly veiled one is a blur
    with a way back.

    Kept as a pure function so this can be tested exhaustively without needing
    explicit imagery to hand — see test_decide.py.
    """
    labels: dict[str, float] = {}
    verdict = "clean"

    def escalate(to: str) -> None:
        nonlocal verdict
        rank = {"clean": 0, "sensitive": 1, "blocked": 2}
        if rank[to] > rank[verdict]:
            verdict = to

    for item in detections or []:
        name = str(item.get("class") or item.get("label") or "")
        if not name:
            continue
        try:
            score = float(item.get("score") or 0)
        except (TypeError, ValueError):
            continue
        labels[name] = max(labels.get(name, 0.0), score)

        if name in NUDITY_EXPOSED:
            if score >= BLOCK_AT:
                escalate("blocked")
            elif score >= NUDITY_VEIL_AT:
                escalate("sensitive")
        elif name in SUGGESTIVE and score >= SUGGESTIVE_AT:
            # Never escalates past sensitive, whatever the confidence. Clothed
            # is not nudity, and no amount of model certainty makes it so.
            escalate("sensitive")

    return verdict, labels


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
        try:
            detections = detector().detect(tmp.name)
        except HTTPException:
            raise
        except Exception as exc:
            # Undecodable bytes with an image extension land here. media-scan
            # already treats any non-ok answer as unsafe and quarantines, so
            # this is not a safety hole either way — but an unhandled traceback
            # in a safety service buries the failures that do matter, and
            # "Internal Server Error" tells the caller nothing it can act on.
            raise HTTPException(status_code=400, detail="undecodable_image") from exc

    verdict, labels = decide(detections)
    return {"verdict": verdict, "labels": labels, "csam": False}
