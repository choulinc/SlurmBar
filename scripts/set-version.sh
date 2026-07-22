#!/usr/bin/env bash
#
# Propagate the version in ./VERSION to every place that repeats it.
#
#     ./scripts/set-version.sh          # apply VERSION everywhere
#     ./scripts/set-version.sh 0.3.0    # set VERSION first, then apply
#
# The version lives in five files across three languages. Editing them by hand means one of
# them is eventually wrong; `test_version_consistency.py` fails the build when they drift.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ $# -ge 1 ]]; then
    printf '%s\n' "$1" > VERSION
fi

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION must be MAJOR.MINOR.PATCH, got '$VERSION'" >&2
    exit 1
fi

sed -i '' -E "s/^version = \".*\"/version = \"$VERSION\"/" agent/pyproject.toml progress/pyproject.toml
sed -i '' -E "s/^AGENT_VERSION = \".*\"/AGENT_VERSION = \"$VERSION\"/" agent/slurmbar_agent/protocol.py
sed -i '' -E "s|^WRITER = \"slurmbar_progress/.*\"|WRITER = \"slurmbar_progress/$VERSION\"|" progress/slurmbar_progress/reporter.py
sed -i '' -E "s/^__version__ = \".*\"/__version__ = \"$VERSION\"/" progress/slurmbar_progress/__init__.py

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" app/Resources/Info.plist

echo "Set version $VERSION in:"
echo "  VERSION"
echo "  agent/pyproject.toml, agent/slurmbar_agent/protocol.py"
echo "  progress/pyproject.toml, progress/slurmbar_progress/{__init__,reporter}.py"
echo "  app/Resources/Info.plist"
