"""``slurmbar-agent doctor`` — everything the app's Test Connection button reports.

Every check is independent and nonfatal. A cluster with no accounting is perfectly usable;
the report says so instead of failing.
"""

from __future__ import annotations

import json
import os
import platform
import socket
import sys
from typing import Any, Dict, List, Optional

from . import progress as progress_mod
from .protocol import AGENT_VERSION, SCHEMA_VERSION, WarningCollector
from .runner import CommandRunner
from .timeutil import iso_utc, utc_now

OK, WARN, FAIL, SKIP = "ok", "warn", "fail", "skip"

SLURM_COMMANDS = ("squeue", "sacct", "sstat", "scancel", "scontrol", "sinfo")


def _check(
    check_id: str, title: str, status: str, detail: Optional[str] = None, value: Optional[str] = None
) -> Dict[str, Any]:
    return {"id": check_id, "title": title, "status": status, "detail": detail, "value": value}


def run_doctor(
    runner: CommandRunner,
    progress_dir: Optional[str] = None,
    user: Optional[str] = None,
    timeout: float = 12.0,
) -> Dict[str, Any]:
    checks: List[Dict[str, Any]] = []
    warnings = WarningCollector()

    checks.append(
        _check("agent", "SlurmBar agent", OK, f"Agent {AGENT_VERSION}, protocol v{SCHEMA_VERSION}.", AGENT_VERSION)
    )

    python_version = platform.python_version()
    if sys.version_info < (3, 7):
        checks.append(
            _check("python", "Remote Python", FAIL, "Python 3.7 or newer is required.", python_version)
        )
    else:
        checks.append(_check("python", "Remote Python", OK, sys.executable, python_version))

    try:
        hostname = socket.getfqdn() or socket.gethostname()
    except OSError:
        hostname = None
    checks.append(
        _check("hostname", "Login node", OK if hostname else WARN, None, hostname)
    )

    # --- Slurm client commands ---------------------------------------------------------
    found = {name: runner.which(name) for name in SLURM_COMMANDS}
    missing = [name for name, path in found.items() if path is None]
    if found.get("squeue") is None:
        checks.append(
            _check(
                "slurm_commands",
                "Slurm commands",
                FAIL,
                "squeue was not found. Slurm client commands may not be on PATH for "
                "non-interactive SSH sessions — try a login shell or an absolute path.",
                ", ".join(sorted(name for name, p in found.items() if p)) or None,
            )
        )
    elif missing:
        checks.append(
            _check(
                "slurm_commands",
                "Slurm commands",
                WARN,
                f"Not found: {', '.join(sorted(missing))}. Related features are disabled.",
                ", ".join(sorted(name for name, p in found.items() if p)),
            )
        )
    else:
        checks.append(_check("slurm_commands", "Slurm commands", OK, None, ", ".join(SLURM_COMMANDS)))

    # --- Slurm version ------------------------------------------------------------------
    version = _slurm_version(runner, timeout)
    checks.append(
        _check("slurm_version", "Slurm version", OK if version else WARN,
               None if version else "Could not determine the Slurm version.", version)
    )

    # --- squeue -------------------------------------------------------------------------
    if found.get("squeue") is None:
        checks.append(_check("squeue", "squeue", SKIP, "squeue is not installed."))
        checks.append(_check("squeue_json", "squeue --json", SKIP, "squeue is not installed."))
    else:
        argv = ["squeue", "--noheader", "-o", "%i"]
        if user:
            argv += ["--user", user]
        result = runner.run(argv, timeout=timeout)
        if result.ok:
            count = len([ln for ln in result.stdout.splitlines() if ln.strip()])
            checks.append(_check("squeue", "squeue", OK, None, f"{count} job(s) in queue"))
        elif result.timed_out:
            checks.append(_check("squeue", "squeue", FAIL, "squeue timed out."))
        else:
            checks.append(_check("squeue", "squeue", FAIL, result.failure_summary()))

        json_argv = ["squeue", "--json"]
        if user:
            json_argv += ["--user", user]
        json_result = runner.run(json_argv, timeout=timeout)
        if json_result.ok and _looks_like_json(json_result.stdout):
            checks.append(
                _check("squeue_json", "squeue --json", OK, "Structured queue output is available.")
            )
        else:
            checks.append(
                _check(
                    "squeue_json",
                    "squeue --json",
                    WARN,
                    "Not supported; SlurmBar will use machine-readable text output instead.",
                    None,
                )
            )

    # --- accounting ---------------------------------------------------------------------
    if found.get("sacct") is None:
        checks.append(
            _check("sacct", "Accounting (sacct)", WARN, "sacct is not installed; finished jobs are unavailable.")
        )
    else:
        argv = ["sacct", "--noheader", "--parsable2", "--allocations",
                "--starttime=now-1hours", "--format=JobID"]
        if user:
            argv += ["--user", user]
        result = runner.run(argv, timeout=timeout)
        if result.ok:
            checks.append(_check("sacct", "Accounting (sacct)", OK, "Job history is available."))
        else:
            checks.append(
                _check(
                    "sacct",
                    "Accounting (sacct)",
                    WARN,
                    "Accounting is unavailable; recently finished jobs will not be shown. "
                    + result.failure_summary(),
                )
            )

    # --- sstat ---------------------------------------------------------------------------
    if found.get("sstat") is None:
        checks.append(
            _check("sstat", "Live usage (sstat)", WARN, "sstat is not installed; live memory is unavailable.")
        )
    else:
        checks.append(
            _check(
                "sstat",
                "Live usage (sstat)",
                OK,
                "Available. Live memory still requires an active job step and is reported as peak RSS.",
            )
        )

    # --- progress directory ---------------------------------------------------------------
    resolved = os.path.expanduser(progress_dir or progress_mod.default_state_dir())
    checks.append(_progress_check(resolved))

    ok = not any(c["status"] == FAIL for c in checks)
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": iso_utc(utc_now()),
        "agent_version": AGENT_VERSION,
        "ok": ok,
        "hostname": hostname,
        "python_version": python_version,
        "checks": checks,
        "warnings": warnings.to_json(),
    }


def _progress_check(resolved: str) -> Dict[str, Any]:
    if not os.path.exists(resolved):
        return _check(
            "progress_dir",
            "Progress directory",
            WARN,
            "Not present yet. It is created the first time a job reports progress with "
            "slurmbar_progress. Slurm state and runtime work without it.",
            resolved,
        )
    if not os.path.isdir(resolved):
        return _check("progress_dir", "Progress directory", FAIL, "Path exists but is not a directory.", resolved)
    if not os.access(resolved, os.R_OK | os.X_OK):
        return _check("progress_dir", "Progress directory", FAIL, "Permission denied.", resolved)
    try:
        entries = [e for e in os.listdir(resolved) if not e.startswith(".")]
    except OSError as exc:
        return _check("progress_dir", "Progress directory", FAIL, str(exc), resolved)
    return _check(
        "progress_dir",
        "Progress directory",
        OK,
        f"{len(entries)} job director{'y' if len(entries) == 1 else 'ies'} present.",
        resolved,
    )


def _slurm_version(runner: CommandRunner, timeout: float) -> Optional[str]:
    for argv in (["sinfo", "--version"], ["squeue", "--version"], ["scontrol", "--version"]):
        if runner.which(argv[0]) is None:
            continue
        result = runner.run(argv, timeout=timeout)
        if result.ok and result.stdout.strip():
            return result.stdout.strip().splitlines()[0].strip()
    return None


def _looks_like_json(payload: str) -> bool:
    text = payload.strip()
    if not text.startswith("{"):
        return False
    try:
        document = json.loads(text)
    except json.JSONDecodeError:
        return False
    return isinstance(document, dict) and isinstance(document.get("jobs"), list)
