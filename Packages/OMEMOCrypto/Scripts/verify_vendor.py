#!/usr/bin/env python3
"""Verify the exact pinned, unmodified cryptographic dependency source inventory."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "VendorManifest.json").read_text())
failures = []
for dependency in manifest["dependencies"]:
    for record in dependency["files"]:
        path = root / record["path"]
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
            failures.append(record["path"])
if failures:
    raise SystemExit("Vendored source mismatch: " + ", ".join(failures))
print("Verified pinned, unmodified libomemo-c and protobuf-c sources and licenses.")
