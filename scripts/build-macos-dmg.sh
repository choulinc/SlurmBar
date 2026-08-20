#!/usr/bin/env bash
# Build a drag-to-Applications disk image with a stable release asset name.
#
#   ./scripts/build-macos-dmg.sh
#   ./scripts/build-macos-dmg.sh --skip-build
#
# Optional distribution environment:
#   SLURMBAR_CODESIGN_IDENTITY="Developer ID Application: ..."
#   SLURMBAR_NOTARY_PROFILE="notarytool-keychain-profile"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/out/SlurmBar.app"
OUTPUT="$REPO_ROOT/out/SlurmBar-macOS.dmg"

if [[ "${1:-}" != "--skip-build" ]]; then
    "$REPO_ROOT/scripts/build-macos-app.sh"
elif [[ ! -d "$APP" ]]; then
    echo "error: $APP does not exist; run without --skip-build first." >&2
    exit 1
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/slurmbar-dmg.XXXXXX")"
cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

cp -R "$APP" "$STAGING/SlurmBar.app"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
echo "==> Building $OUTPUT"
hdiutil create \
    -volname "SlurmBar" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$OUTPUT"

if [[ -n "${SLURMBAR_CODESIGN_IDENTITY:-}" ]]; then
    echo "==> Signing the disk image"
    codesign --force --timestamp --sign "$SLURMBAR_CODESIGN_IDENTITY" "$OUTPUT"
fi

if [[ -n "${SLURMBAR_NOTARY_PROFILE:-}" ]]; then
    if [[ -z "${SLURMBAR_CODESIGN_IDENTITY:-}" ]]; then
        echo "error: notarization requires SLURMBAR_CODESIGN_IDENTITY too." >&2
        exit 1
    fi
    echo "==> Submitting for notarization"
    xcrun notarytool submit "$OUTPUT" \
        --keychain-profile "$SLURMBAR_NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$OUTPUT"
    xcrun stapler validate "$OUTPUT"
fi

SIZE="$(du -h "$OUTPUT" | awk '{print $1}')"
SHA256="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
cat <<SUMMARY

Built $OUTPUT
  Size:    $SIZE
  SHA-256: $SHA256

Upload this exact filename to every GitHub release so the permanent download URL stays valid:
  https://github.com/choulinc/SlurmBar/releases/latest/download/SlurmBar-macOS.dmg
SUMMARY
