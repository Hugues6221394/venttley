#!/usr/bin/env python3
"""Put the avatar presets in the bucket, once, for everybody.

    python3 scripts/seed/upload_avatar_presets.py \
        --api https://… --service-key "$KEY"

A reader cannot see another account's app bundle, so a feed row resolves an
author's avatar through a URL like any other photo. These are the files behind
that URL — ten shared objects, not a copy per account.
"""

import argparse
import pathlib
import subprocess
import sys

BUCKET = "profile-photos"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", required=True)
    ap.add_argument("--service-key", required=True)
    a = ap.parse_args()

    src = pathlib.Path("assets/images/avatars")
    files = sorted(src.glob("a*.webp"))
    if not files:
        sys.exit("no avatars found in assets/images/avatars")

    for f in files:
        path = f"presets/{f.name}"
        for attempt in range(1, 4):
            r = subprocess.run(
                [
                    "curl", "-sS", "--max-time", "45", "-X", "POST",
                    f"{a.api}/storage/v1/object/{BUCKET}/{path}",
                    "-H", f"Authorization: Bearer {a.service_key}",
                    "-H", "Content-Type: image/webp",
                    "-H", "x-upsert: true",
                    "--data-binary", f"@{f}",
                ],
                capture_output=True, text=True,
            )
            body = (r.stdout or "") + (r.stderr or "")
            ok = r.returncode == 0 and not (
                "error" in body.lower() and "exists" not in body.lower()
            )
            if ok:
                print(f"  {f.name} -> {path}")
                break
            if attempt == 3:
                sys.exit(f"upload failed for {f.name}: {body[:300]}")
    print(f"{len(files)} presets uploaded")


if __name__ == "__main__":
    main()
