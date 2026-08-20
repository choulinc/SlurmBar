#!/usr/bin/env bash
# Verify the app bundle, embedded agent and drag-to-Applications disk image.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/out/SlurmBar.app"
DMG="$REPO_ROOT/out/SlurmBar-macOS.dmg"
EXPECTED_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"

[[ -d "$APP" ]] || { echo "error: missing $APP" >&2; exit 1; }
[[ -f "$DMG" ]] || { echo "error: missing $DMG" >&2; exit 1; }

echo "==> Verifying the app signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Verifying the embedded agent"
EMBEDDED_AGENT="$APP/Contents/Resources/slurmbar-agent.pyz"
[[ -f "$EMBEDDED_AGENT" ]] || { echo "error: the app does not contain slurmbar-agent.pyz" >&2; exit 1; }
AGENT_VERSION="$(python3 "$EMBEDDED_AGENT" --version)"
[[ "$AGENT_VERSION" == "slurmbar-agent $EXPECTED_VERSION" ]] || {
    echo "error: embedded agent version is '$AGENT_VERSION', expected $EXPECTED_VERSION" >&2
    exit 1
}

echo "==> Verifying the disk image"
hdiutil verify "$DMG"

MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/slurmbar-dmg-verify.XXXXXX")"
MOUNTED=0
cleanup() {
    if [[ "$MOUNTED" -eq 1 ]]; then
        hdiutil detach "$MOUNT_POINT" -quiet || true
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
MOUNTED=1
[[ -d "$MOUNT_POINT/SlurmBar.app" ]] || { echo "error: DMG is missing SlurmBar.app" >&2; exit 1; }
[[ -L "$MOUNT_POINT/Applications" ]] || { echo "error: DMG is missing the Applications shortcut" >&2; exit 1; }
codesign --verify --deep --strict "$MOUNT_POINT/SlurmBar.app"

hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0
rmdir "$MOUNT_POINT"
trap - EXIT

echo "Release artifacts verified for SlurmBar $EXPECTED_VERSION."
