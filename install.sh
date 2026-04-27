#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UIVISION_ROOT="${1:-${UIVISION_ROOT:-$HOME/Desktop/uivision}}"
MACROS_DIR="$UIVISION_ROOT/macros"

mkdir -p "$MACROS_DIR"

export SCRIPT_DIR
export MACROS_DIR

python3 - <<'PY'
import json
import os
import shutil
from pathlib import Path

script_dir = Path(os.environ["SCRIPT_DIR"])
macros_dir = Path(os.environ["MACROS_DIR"])

copied = 0
skipped = 0

for json_file in sorted(script_dir.rglob("*.json")):
    try:
        with json_file.open(encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception as exc:
        print(f"Skipping {json_file}: could not parse JSON ({exc})")
        skipped += 1
        continue

    macro_name = str(data.get("Name") or "").strip()
    commands = data.get("Commands")
    if not macro_name or not isinstance(commands, list):
        print(f"Skipping {json_file}: not a UI.Vision macro JSON")
        skipped += 1
        continue

    destination = macros_dir / f"{macro_name}.json"
    shutil.copy2(json_file, destination)
    print(f"Installed {json_file.relative_to(script_dir)} -> {destination}")
    copied += 1

print(f"Done. Installed {copied} macro file(s) to {macros_dir}")
if skipped:
    print(f"Skipped {skipped} file(s) that were not installable macros")
PY
