#!/usr/bin/env python3
"""Assert a multi-arch OCI index carries exactly one image per built platform.

Reads the raw index JSON (`docker buildx imagetools inspect --raw <ref>`) from
a file or stdin. Attestation entries (buildkit provenance/SBOM) ride in the
index beside the images; they are told apart by the
`vnd.docker.reference.type` annotation, never by platform alone, and do not
count as an image. Exit 1 unless every requested platform has exactly one
image entry and no other platform is present.

Usage: assert-index-platforms.py linux/amd64,linux/arm64 [index.json]
"""

from __future__ import annotations

import json
import sys
from collections import Counter

ATTESTATION_ANNOTATION = "vnd.docker.reference.type"


def is_attestation(entry: dict) -> bool:
    return ATTESTATION_ANNOTATION in (entry.get("annotations") or {})


def platform_of(entry: dict) -> str:
    platform = entry.get("platform") or {}
    return f"{platform.get('os', '')}/{platform.get('architecture', '')}"


def problems(index: dict, expected: list[str]) -> list[str]:
    entries = index.get("manifests")
    if not isinstance(entries, list):
        return ["document is not an image index (no manifests list)"]
    found = Counter(platform_of(e) for e in entries if not is_attestation(e))
    issues = [
        f"{platform}: {found.get(platform, 0)} image entries, expected exactly 1"
        for platform in expected
        if found.get(platform, 0) != 1
    ]
    issues += [f"unexpected platform {p}" for p in sorted(found) if p not in expected]
    return issues


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    expected = [p for p in argv[1].split(",") if p]
    raw = open(argv[2]).read() if len(argv) == 3 else sys.stdin.read()
    try:
        index = json.loads(raw)
    except json.JSONDecodeError as error:
        print(f"::error::index is not JSON: {error}")
        return 1
    issues = problems(index, expected)
    for issue in issues:
        print(f"::error::{issue}")
    if not issues:
        print(f"index OK: one image per {', '.join(expected)}")
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
