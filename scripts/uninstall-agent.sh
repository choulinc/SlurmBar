#!/usr/bin/env bash
#
# Remove slurmbar-agent from your account on a remote cluster.
#
#     ./scripts/uninstall-agent.sh <ssh-alias> [--purge-progress]
#
# Removes only the two files install-agent.sh created. Progress state written by your own jobs
# is left alone unless you explicitly pass --purge-progress.

set -euo pipefail

ALIAS="${1:-}"
if [[ -z "$ALIAS" ]]; then
    echo "usage: ./scripts/uninstall-agent.sh <ssh-alias> [--purge-progress]" >&2
    exit 2
fi
if [[ "$ALIAS" == -* || "$ALIAS" =~ [[:space:][:cntrl:]] ]]; then
    echo "error: SSH alias must not start with '-' or contain whitespace/control characters." >&2
    exit 2
fi
shift

PURGE_PROGRESS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-progress) PURGE_PROGRESS=1; shift ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
done

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)

echo "==> Removing the agent from $ALIAS"
ssh "${SSH_OPTS[@]}" "$ALIAS" '
    rm -f "$HOME/.local/share/slurmbar/slurmbar-agent.pyz"
    rm -f "$HOME/.local/bin/slurmbar-agent"
    # Only remove the directory if it is now empty; never delete anything else in it.
    rmdir "$HOME/.local/share/slurmbar" 2>/dev/null || true
    echo "    agent removed"
'

if [[ "$PURGE_PROGRESS" -eq 1 ]]; then
    echo "==> Removing progress state (~/.local/state/slurmbar/jobs)"
    read -r -p "    This deletes progress files written by your jobs. Continue? [y/N] " reply
    case "$reply" in
        [yY]*)
            ssh "${SSH_OPTS[@]}" "$ALIAS" 'rm -rf "$HOME/.local/state/slurmbar/jobs" && echo "    progress state removed"'
            ;;
        *)
            echo "    skipped"
            ;;
    esac
else
    echo "==> Leaving progress state in ~/.local/state/slurmbar/jobs (pass --purge-progress to remove)"
fi

cat <<'SUMMARY'

Done. Nothing was changed outside your home directory, and no startup files were touched.
Remember to remove the cluster from SlurmBar's Settings on your Mac if you no longer need it.
SUMMARY
