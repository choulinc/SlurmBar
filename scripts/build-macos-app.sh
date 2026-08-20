#!/usr/bin/env bash
#
# Build SlurmBar.app from the Swift package.
#
#     ./scripts/build-macos-app.sh [--debug]
#
# SwiftPM produces a bare executable; a menu bar app needs a real bundle for LSUIElement,
# UserNotifications and SMAppService (launch at login) to work at all. This assembles one and
# embeds the remote agent and signs it. The default ad-hoc signature is enough for local use;
# set SLURMBAR_CODESIGN_IDENTITY to a Developer ID Application identity for distribution.
#
# For distribution to other machines you still need a Developer ID signature and notarization.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"

CONFIGURATION="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIGURATION="debug"
fi

OUTPUT="$REPO_ROOT/out/SlurmBar.app"

echo "==> Building ($CONFIGURATION)"
cd "$APP_DIR"
swift build -c "$CONFIGURATION" --product SlurmBar

BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/SlurmBar"
if [[ ! -x "$BINARY" ]]; then
    echo "error: expected executable at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $OUTPUT"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"

cp "$BINARY" "$OUTPUT/Contents/MacOS/SlurmBar"
cp "$APP_DIR/Resources/Info.plist" "$OUTPUT/Contents/Info.plist"
printf 'APPL????' > "$OUTPUT/Contents/PkgInfo"

echo "==> Building the app icon"
if "$REPO_ROOT/scripts/make-app-icon.sh" "$OUTPUT/Contents/Resources/AppIcon.icns" >/dev/null; then
    echo "    AppIcon.icns"
else
    # The app is perfectly usable with the generic icon; do not fail the build over artwork.
    echo "    warning: could not build the icon; the app will use the generic one." >&2
fi

echo "==> Embedding the remote agent"
"$REPO_ROOT/scripts/build-agent-zipapp.sh" \
    "$OUTPUT/Contents/Resources/slurmbar-agent.pyz" >/dev/null
echo "    slurmbar-agent.pyz"

SIGN_IDENTITY="${SLURMBAR_CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> Signing (ad-hoc)"
    SIGN_OPTIONS=(--force --deep --sign -)
else
    echo "==> Signing with Developer ID"
    SIGN_OPTIONS=(--force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi
# UNUserNotificationCenter and SMAppService both require a signed bundle. An ad-hoc signature
# satisfies them locally; public distribution still requires Developer ID plus notarization.
codesign "${SIGN_OPTIONS[@]}" "$OUTPUT" 2>&1 | sed 's/^/    /' || {
    echo "    warning: codesign failed; notifications and launch-at-login may not work." >&2
}

cat <<SUMMARY

Built $OUTPUT

Run it:
  open "$OUTPUT"

Install it (needed for Launch at Login):
  cp -R "$OUTPUT" /Applications/

SlurmBar has no Dock icon or window — look for the server icon in the menu bar. On first
launch, open its Settings and add a cluster using an SSH alias that already works in Terminal.
SUMMARY
