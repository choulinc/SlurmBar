#!/usr/bin/env bash
#
# Launch SlurmBar against the demo snapshot, for documentation screenshots.
#
#     ./demo/run-demo.sh
#
# No cluster is contacted. Setting SLURMBAR_DEMO_SNAPSHOT also redirects the app's settings and
# snapshot cache into a scratch directory, so your real cluster profile and its cached jobs are
# never read or overwritten.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

python3 demo/make-demo-snapshot.py > demo/snapshot.json
echo "==> Regenerated demo/snapshot.json (elapsed times are relative to now)"

[[ -x out/SlurmBar.app/Contents/MacOS/SlurmBar ]] || ./scripts/build-macos-app.sh >/dev/null

pkill -x SlurmBar 2>/dev/null || true
sleep 1

echo "==> Launching in demo mode"
SLURMBAR_DEMO_SNAPSHOT="$REPO_ROOT/demo/snapshot.json" \
    ./out/SlurmBar.app/Contents/MacOS/SlurmBar &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT

sleep 3
cat <<'TIP'

SlurmBar is now showing fabricated jobs. Click the menu bar icon, then:

  Capture just the popover:  ⌘⇧4, then Space, then click the popover.
                             You get the window with its shadow and a
                             transparent background — ideal for a README.

  Suggested shots:           the job list; a job's detail page; the trash
                             menu; Settings > Clusters after Test Connection.

Press Ctrl-C when you are done.
TIP
wait "$APP_PID"
