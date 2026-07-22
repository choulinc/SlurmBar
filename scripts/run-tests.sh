#!/usr/bin/env bash
#
# Run every test suite in the repository.
#
#     ./scripts/run-tests.sh
#
# Everything is fixture-driven; no Slurm cluster and no SSH access are needed. `scancel` is
# never executed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FAILURES=0
run_suite() {
    local name="$1"
    shift
    echo
    echo "════════════════════════════════════════════════════════════"
    echo "  $name"
    echo "════════════════════════════════════════════════════════════"
    if "$@"; then
        echo "  ✓ $name passed"
    else
        echo "  ✗ $name FAILED"
        FAILURES=$((FAILURES + 1))
    fi
}

# --- Python -------------------------------------------------------------------------------

PYTHON="${PYTHON:-}"
if [[ -z "$PYTHON" ]]; then
    if [[ -x "$REPO_ROOT/.venv/bin/python" ]]; then
        PYTHON="$REPO_ROOT/.venv/bin/python"
    else
        PYTHON="python3"
    fi
fi

if "$PYTHON" -c 'import pytest' 2>/dev/null; then
    run_suite "Agent (Python)" env -C "$REPO_ROOT/agent" "$PYTHON" -m pytest tests/ -q
    run_suite "Progress SDK (Python)" env -C "$REPO_ROOT/progress" "$PYTHON" -m pytest tests/ -q
else
    echo "skipping Python suites: pytest not available for $PYTHON"
    echo "  python3 -m venv .venv && .venv/bin/pip install pytest jsonschema"
    FAILURES=$((FAILURES + 1))
fi

# --- Swift --------------------------------------------------------------------------------

if command -v swift >/dev/null 2>&1; then
    run_suite "SlurmBarKit (Swift)" env -C "$REPO_ROOT/app" swift test
else
    echo
    echo "skipping Swift suite: no swift toolchain found"
fi

# --- Packaging ----------------------------------------------------------------------------

run_suite "Agent zipapp builds and runs" bash -c \
    '"'"$REPO_ROOT"'/scripts/build-agent-zipapp.sh" >/dev/null'

echo
echo "════════════════════════════════════════════════════════════"
if [[ "$FAILURES" -eq 0 ]]; then
    echo "  All suites passed."
else
    echo "  $FAILURES suite(s) failed."
fi
echo "════════════════════════════════════════════════════════════"
exit "$FAILURES"
