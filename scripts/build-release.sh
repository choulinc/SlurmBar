#!/usr/bin/env bash
# Build the two stable-name assets attached to a GitHub release.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$REPO_ROOT/scripts/build-macos-app.sh"
"$REPO_ROOT/scripts/build-macos-dmg.sh" --skip-build
"$REPO_ROOT/scripts/build-agent-zipapp.sh" "$REPO_ROOT/out/slurmbar-agent.pyz"
"$REPO_ROOT/scripts/verify-release.sh"

echo
echo "Release assets:"
shasum -a 256 \
    "$REPO_ROOT/out/SlurmBar-macOS.dmg" \
    "$REPO_ROOT/out/slurmbar-agent.pyz"
