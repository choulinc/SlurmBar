#!/usr/bin/env bash
#
# Build slurmbar-agent.pyz — a self-contained Python zipapp.
#
# A zipapp is the right shape for this job: one file to copy, no pip, no virtualenv, no write
# access outside the user's home directory, and no third-party dependencies to resolve on a
# login node that may have none.
#
# Usage: ./scripts/build-agent-zipapp.sh [output-path]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$REPO_ROOT/out/slurmbar-agent.pyz}"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "error: $PYTHON not found. Set PYTHON=/path/to/python3 and retry." >&2
    exit 1
fi

echo "==> Staging slurmbar_agent"
mkdir -p "$BUILD_DIR/slurmbar_agent"
cp "$REPO_ROOT"/agent/slurmbar_agent/*.py "$BUILD_DIR/slurmbar_agent/"

# The zipapp entry point. `python3 agent.pyz snapshot --json` lands here.
cat > "$BUILD_DIR/__main__.py" <<'PY'
import sys

from slurmbar_agent.cli import main

if __name__ == "__main__":
    sys.exit(main())
PY

# Drop caches so the archive is reproducible.
find "$BUILD_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

mkdir -p "$(dirname "$OUTPUT")"

echo "==> Building zipapp"
# -p sets the shebang so the file is directly executable too. Compression keeps it small
# enough to paste over a slow link if scp is unavailable.
"$PYTHON" -m zipapp "$BUILD_DIR" \
    --output "$OUTPUT" \
    --python "/usr/bin/env python3" \
    --compress

chmod +x "$OUTPUT"

echo "==> Verifying"
VERSION="$("$PYTHON" "$OUTPUT" --version)"
"$PYTHON" "$OUTPUT" paths >/dev/null

SIZE="$(wc -c < "$OUTPUT" | tr -d ' ')"
echo
echo "Built $OUTPUT"
echo "  $VERSION"
echo "  ${SIZE} bytes"
