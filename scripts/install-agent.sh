#!/usr/bin/env bash
#
# Install slurmbar-agent into your account on a remote cluster.
#
#     ./scripts/install-agent.sh <ssh-alias>
#
# What it does, and nothing else:
#   * builds the zipapp locally
#   * creates ~/.local/share/slurmbar and ~/.local/bin in YOUR home directory on the cluster
#   * copies one file there
#   * writes a small launcher script
#   * runs `doctor` and prints the result
#
# What it deliberately does not do:
#   * use sudo, or write anywhere outside your home directory
#   * modify .bashrc, .zshrc, .profile or any other startup file
#   * install a daemon, a systemd unit, a cron job, or open any port
#   * copy, read or create SSH keys

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ALIAS="${1:-}"
if [[ -z "$ALIAS" ]]; then
    cat >&2 <<'USAGE'
usage: ./scripts/install-agent.sh <ssh-alias> [--python PATH]

  <ssh-alias>   A Host entry from your ~/.ssh/config, or user@hostname.

Examples:
  ./scripts/install-agent.sh my-cluster
  ./scripts/install-agent.sh my-cluster --python /opt/python3.11/bin/python3
USAGE
    exit 2
fi
shift

REMOTE_PYTHON="python3"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --python) REMOTE_PYTHON="${2:?--python needs a value}"; shift 2 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
done

REMOTE_DIR='$HOME/.local/share/slurmbar'
REMOTE_BIN='$HOME/.local/bin'
PYZ_NAME="slurmbar-agent.pyz"
LOCAL_PYZ="$REPO_ROOT/out/$PYZ_NAME"

# BatchMode keeps this script from ever hanging on a password prompt, matching the app.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)

echo "==> Building the agent"
"$REPO_ROOT/scripts/build-agent-zipapp.sh" "$LOCAL_PYZ" >/dev/null
echo "    $LOCAL_PYZ"

echo "==> Checking SSH access to $ALIAS"
if ! ssh "${SSH_OPTS[@]}" "$ALIAS" true 2>/tmp/slurmbar-ssh-check.$$; then
    echo "error: cannot connect to '$ALIAS' without a prompt." >&2
    sed 's/^/    /' /tmp/slurmbar-ssh-check.$$ >&2 || true
    rm -f /tmp/slurmbar-ssh-check.$$
    cat >&2 <<'HINT'

    SlurmBar uses your existing OpenSSH setup and never prompts for a password.
    Make sure `ssh <alias>` works non-interactively first:
      * load your key:            ssh-add ~/.ssh/id_ed25519
      * accept the host key once: ssh <alias>
      * connect to the VPN if the cluster requires one
HINT
    exit 1
fi
rm -f /tmp/slurmbar-ssh-check.$$

echo "==> Checking remote Python"
if ! REMOTE_PY_VERSION="$(ssh "${SSH_OPTS[@]}" "$ALIAS" "command -v $REMOTE_PYTHON >/dev/null && $REMOTE_PYTHON -c 'import sys; print(\".\".join(map(str, sys.version_info[:3])))'" 2>/dev/null)"; then
    echo "error: '$REMOTE_PYTHON' was not found on $ALIAS." >&2
    echo "       Re-run with --python /absolute/path/to/python3, or load a Python module first." >&2
    exit 1
fi
echo "    $REMOTE_PYTHON $REMOTE_PY_VERSION"

echo "==> Creating directories in your home directory on $ALIAS"
ssh "${SSH_OPTS[@]}" "$ALIAS" "mkdir -p $REMOTE_DIR $REMOTE_BIN"

echo "==> Backing up any existing agent"
ssh "${SSH_OPTS[@]}" "$ALIAS" "
    if [ -f $REMOTE_DIR/$PYZ_NAME ]; then
        cp -p $REMOTE_DIR/$PYZ_NAME $REMOTE_DIR/$PYZ_NAME.\$(date +%Y%m%d-%H%M%S).bak
        echo '    backed up previous agent'
    else
        echo '    no previous agent'
    fi
"

echo "==> Uploading the agent"
# Try scp, but fall back to piping over the ssh transport. Some sites disable the sftp
# subsystem that modern scp uses, so scp existing locally does not mean it works remotely.
if ! scp -q -o BatchMode=yes "$LOCAL_PYZ" "$ALIAS:.local/share/slurmbar/$PYZ_NAME" 2>/dev/null; then
    echo "    scp unavailable on this host; piping over ssh instead"
    ssh "${SSH_OPTS[@]}" "$ALIAS" "cat > $REMOTE_DIR/$PYZ_NAME" < "$LOCAL_PYZ"
fi
ssh "${SSH_OPTS[@]}" "$ALIAS" "chmod 0755 $REMOTE_DIR/$PYZ_NAME"

# Confirm the upload survived intact rather than trusting the transfer.
LOCAL_SIZE="$(wc -c < "$LOCAL_PYZ" | tr -d ' ')"
REMOTE_SIZE="$(ssh "${SSH_OPTS[@]}" "$ALIAS" "wc -c < $REMOTE_DIR/$PYZ_NAME" | tr -d ' ')"
if [[ "$LOCAL_SIZE" != "$REMOTE_SIZE" ]]; then
    echo "error: upload size mismatch (local $LOCAL_SIZE, remote $REMOTE_SIZE)." >&2
    exit 1
fi
echo "    uploaded $REMOTE_SIZE bytes"

echo "==> Installing the launcher at ~/.local/bin/slurmbar-agent"
ssh "${SSH_OPTS[@]}" "$ALIAS" "cat > $REMOTE_BIN/slurmbar-agent && chmod 0755 $REMOTE_BIN/slurmbar-agent" <<LAUNCHER
#!/bin/sh
# Installed by SlurmBar's install-agent.sh. Safe to delete.
exec $REMOTE_PYTHON "\$HOME/.local/share/slurmbar/$PYZ_NAME" "\$@"
LAUNCHER

echo "==> Running doctor on $ALIAS"
echo
DOCTOR_JSON="$(ssh "${SSH_OPTS[@]}" "$ALIAS" "$REMOTE_PYTHON \$HOME/.local/share/slurmbar/$PYZ_NAME doctor --json" || true)"

if command -v python3 >/dev/null 2>&1 && [[ -n "$DOCTOR_JSON" ]]; then
    printf '%s' "$DOCTOR_JSON" | python3 -c '
import json, sys

raw = sys.stdin.read()
try:
    report = json.loads(raw)
except ValueError:
    print("    Could not parse the doctor output:")
    print("   ", raw[:500])
    raise SystemExit(1)

LABELS = {"ok": "  ok  ", "warn": " warn ", "fail": " FAIL ", "skip": " skip "}
for check in report.get("checks", []):
    status = check.get("status", "?")
    title = check.get("title", "")
    line = "  [" + LABELS.get(status, status) + "] " + title
    value = check.get("value")
    if value:
        line += ": " + str(value)
    print(line)
    detail = check.get("detail")
    if detail and status in ("warn", "fail"):
        print("           " + str(detail))
print()
print("  Overall: " + ("ready" if report.get("ok") else "NOT READY"))
'
else
    printf '%s\n' "$DOCTOR_JSON"
fi

cat <<SUMMARY

Installed on $ALIAS:
  \$HOME/.local/share/slurmbar/$PYZ_NAME
  \$HOME/.local/bin/slurmbar-agent

In SlurmBar's Settings, add a cluster with:
  SSH alias:      $ALIAS
  Agent command:  $REMOTE_PYTHON ~/.local/share/slurmbar/$PYZ_NAME

If \$HOME/.local/bin is not on your PATH on the cluster, that is fine — SlurmBar calls the
.pyz by its full path and never relies on PATH. To run it by hand from a login shell, use:
  $REMOTE_PYTHON ~/.local/share/slurmbar/$PYZ_NAME doctor --json

To add progress reporting to a workload, install the SDK on the cluster:
  scp -r progress/slurmbar_progress $ALIAS:  # or pip install --user ./progress
SUMMARY
