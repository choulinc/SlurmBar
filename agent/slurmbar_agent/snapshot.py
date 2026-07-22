"""Snapshot assembly — the one function the app calls on every refresh.

Command budget per refresh (worst case):

* 1 × ``squeue``           — the live queue
* 1 × ``sacct --allocations`` — recent history (skipped when accounting is unavailable)
* 1 × ``sacct`` step query  — peak memory of finished jobs
* 1 × ``sstat``            — live memory of running jobs
* 1 × ``sinfo --version``  — cluster identity (cheap, no controller job scan)

That is a fixed count regardless of how many jobs the user has. Nothing is queried per job,
and log files are read only for running jobs that lack structured progress, capped by
``MAX_LOG_FALLBACK_JOBS``.
"""

from __future__ import annotations

import getpass
import os
import socket
from typing import Any, Dict, List, Optional, Sequence

from . import logtail, progress as progress_mod, sacct, sstat, squeue
from .logparse import parse_log_lines
from .protocol import (
    AGENT_VERSION,
    SCHEMA_VERSION,
    STATE_COMPLETED,
    STATE_COMPLETING,
    STATE_PENDING,
    STATE_RUNNING,
    STATE_SUSPENDED,
    FAILURE_STATES,
    WarningCollector,
    W,
)
from .runner import CommandRunner
from .timeutil import iso_utc, utc_now
from .validate import is_valid_job_id

#: How many running jobs may have their logs sniffed for progress in one refresh. Bounded so a
#: user with 200 running jobs does not trigger 200 filesystem reads per poll.
MAX_LOG_FALLBACK_JOBS = 12
LOG_FALLBACK_WINDOW_BYTES = 64 * 1024
LOG_FALLBACK_LINES = 120

DEFAULT_HISTORY_HOURS = 24


def current_username() -> Optional[str]:
    """The account the agent is running as, used to scope queries by default."""
    for name in (os.environ.get("USER"), os.environ.get("LOGNAME")):
        if name and name.strip():
            return name.strip()
    try:
        return getpass.getuser()
    except Exception:  # pragma: no cover - only when the environment has no user at all
        return None


def build_snapshot(
    runner: CommandRunner,
    user: Optional[str] = None,
    all_users: bool = False,
    history_hours: int = DEFAULT_HISTORY_HOURS,
    progress_dir: Optional[str] = None,
    stale_seconds: int = progress_mod.DEFAULT_STALE_SECONDS,
    enable_log_fallback: bool = True,
    enable_sstat: bool = True,
    timeout: float = 15.0,
) -> Dict[str, Any]:
    warnings = WarningCollector()
    now = utc_now()

    # SlurmBar is a personal tool. Without a filter, Slurm may return other users' records and
    # their log paths. Scope to the invoking account unless asked otherwise.
    effective_user = None if all_users else (user or current_username())

    queue_jobs = squeue.collect(runner, effective_user, warnings, timeout=timeout)

    history_jobs: List[Dict[str, Any]] = []
    if history_hours > 0:
        history_jobs = sacct.collect_history(
            runner, effective_user, history_hours, warnings, timeout=timeout
        )

    jobs = _merge(queue_jobs, history_jobs)

    if enable_sstat:
        running_ids = [j["job_id"] for j in jobs if j["state"] == STATE_RUNNING]
        if running_ids:
            usage = sstat.collect_live_usage(runner, running_ids, warnings, timeout=timeout)
            sstat.apply_live_usage(jobs, usage)

    resolved_progress_dir = os.path.expanduser(progress_dir or progress_mod.default_state_dir())
    active_ids = [
        j["job_id"]
        for j in jobs
        if j["state"] in (STATE_RUNNING, STATE_COMPLETING, STATE_PENDING) and is_valid_job_id(j["job_id"])
    ]
    # Recently finished jobs keep their last structured progress, which is how a user sees
    # "stopped at epoch 812/1000" on a failed run.
    finished_ids = [
        j["job_id"] for j in jobs if j["state"] not in (STATE_RUNNING, STATE_COMPLETING, STATE_PENDING)
        and is_valid_job_id(j["job_id"])
    ]
    structured = progress_mod.load_all(
        resolved_progress_dir,
        active_ids + finished_ids,
        warnings,
        stale_seconds=stale_seconds,
        now=now,
    )
    for job in jobs:
        found = structured.get(job["job_id"])
        if found is not None:
            job["progress"] = found

    if enable_log_fallback:
        _apply_log_fallback(jobs, warnings)

    summary = _summarize(jobs)
    cluster = _cluster_info(runner)

    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": iso_utc(now),
        "agent_version": AGENT_VERSION,
        "cluster": cluster,
        "summary": summary,
        "jobs": jobs,
        "warnings": warnings.to_json(),
    }


def _merge(queue_jobs: Sequence[Dict[str, Any]], history_jobs: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """squeue wins for anything still in the queue; sacct fills in what has already left it.

    A job can appear in both while it is completing, and the two sources can disagree (sacct
    lags). The live record is authoritative, but accounting-only fields (exit code, peak
    memory, real end time) are folded in.
    """
    merged: Dict[str, Dict[str, Any]] = {}
    order: List[str] = []

    for job in queue_jobs:
        merged[job["job_id"]] = job
        order.append(job["job_id"])

    for job in history_jobs:
        job_id = job["job_id"]
        existing = merged.get(job_id)
        if existing is None:
            merged[job_id] = job
            order.append(job_id)
            continue
        _fill_missing(existing, job)

    return [merged[job_id] for job_id in order]


_ACCOUNTING_ONLY_FIELDS = ("exit_code", "signal", "end_time", "account", "qos", "time_limit_seconds")


def _fill_missing(live: Dict[str, Any], historical: Dict[str, Any]) -> None:
    # sacct reports ExitCode 0:0 for jobs that are still running. Folding that onto a live
    # record would resurrect the "exit 0 while running" claim the squeue path already rejects.
    still_active = live.get("state") in (
        STATE_PENDING, STATE_RUNNING, STATE_SUSPENDED, STATE_COMPLETING
    )
    for field in _ACCOUNTING_ONLY_FIELDS:
        if still_active and field in ("exit_code", "signal", "end_time"):
            continue
        if live.get(field) is None and historical.get(field) is not None:
            live[field] = historical[field]
    if not live.get("nodes") and historical.get("nodes"):
        live["nodes"] = historical["nodes"]

    live_res, hist_res = live["resources"], historical["resources"]
    if live_res.get("memory_used_bytes") is None and hist_res.get("memory_used_bytes") is not None:
        live_res["memory_used_bytes"] = hist_res["memory_used_bytes"]
        live_res["memory_semantics"] = hist_res["memory_semantics"]
    if live_res.get("memory_limit_bytes") is None and hist_res.get("memory_limit_bytes") is not None:
        live_res["memory_limit_bytes"] = hist_res["memory_limit_bytes"]
        live_res["memory_limit_semantics"] = hist_res["memory_limit_semantics"]
    for key in ("gpu_memory_used_bytes", "gpu_memory_limit_bytes", "gpu_utilization_percent"):
        if live_res.get(key) is None and hist_res.get(key) is not None:
            live_res[key] = hist_res[key]


def _apply_log_fallback(jobs: List[Dict[str, Any]], warnings: WarningCollector) -> None:
    """Sniff the tail of the log for running jobs that have no structured progress."""
    candidates = [
        job
        for job in jobs
        if job["state"] == STATE_RUNNING and job.get("progress") is None and job.get("stdout_path")
    ]
    missing_path = [
        job for job in jobs if job["state"] == STATE_RUNNING and job.get("progress") is None and not job.get("stdout_path")
    ]
    if missing_path:
        warnings.add(
            W.LOG_PATH_UNKNOWN,
            "Log paths are not reported by this Slurm version's queue output.",
            severity="info",
            detail=(
                "Log-based progress fallback is unavailable for "
                f"{len(missing_path)} running job(s); logs can still be opened from the job detail view."
            ),
        )

    for job in candidates[:MAX_LOG_FALLBACK_JOBS]:
        tail = logtail.read_tail(
            job["stdout_path"],
            max_lines=LOG_FALLBACK_LINES,
            window_bytes=LOG_FALLBACK_WINDOW_BYTES,
        )
        if not tail.ok:
            if tail.error_kind == "permission":
                warnings.add(
                    W.LOG_UNREADABLE,
                    f"Permission denied reading the log for job {job['job_id']}.",
                    severity="info",
                    detail=tail.path,
                    job_id=job["job_id"],
                )
            continue
        parsed = parse_log_lines(tail.lines)
        if parsed is None:
            continue
        updated_at = iso_utc(_from_epoch(tail.modified_at))
        job["progress"] = parsed.to_progress_json(updated_at)


def _from_epoch(epoch: Optional[float]):
    if epoch is None:
        return None
    from datetime import datetime, timezone

    return datetime.fromtimestamp(epoch, tz=timezone.utc)


def _summarize(jobs: Sequence[Dict[str, Any]]) -> Dict[str, int]:
    summary = {
        "running": 0,
        "pending": 0,
        "completing": 0,
        "failed_recently": 0,
        "completed_recently": 0,
    }
    for job in jobs:
        state = job["state"]
        if state == STATE_RUNNING:
            summary["running"] += 1
        elif state == STATE_PENDING:
            summary["pending"] += 1
        elif state == STATE_COMPLETING:
            summary["completing"] += 1
        elif state == STATE_COMPLETED:
            summary["completed_recently"] += 1
        elif state in FAILURE_STATES:
            summary["failed_recently"] += 1
    return summary


def _cluster_info(runner: CommandRunner) -> Dict[str, Optional[str]]:
    hostname: Optional[str]
    try:
        hostname = socket.getfqdn() or socket.gethostname()
    except OSError:
        hostname = None

    version: Optional[str] = None
    name: Optional[str] = None

    # One call yields both ClusterName and SLURM_VERSION; no need for a separate sinfo probe.
    if runner.which("scontrol") is not None:
        result = runner.run(["scontrol", "show", "config"], timeout=8.0)
        if result.ok:
            for line in result.stdout.splitlines():
                key, sep, value = line.partition("=")
                if not sep:
                    continue
                key = key.strip()
                value = value.strip()
                if key == "ClusterName" and not name:
                    name = value or None
                elif key == "SLURM_VERSION" and not version:
                    version = value or None
                if name and version:
                    break

    if version is None and runner.which("sinfo") is not None:
        result = runner.run(["sinfo", "--version"], timeout=8.0)
        if result.ok and result.stdout.strip():
            version = result.stdout.strip().splitlines()[0].strip() or None

    return {"name": name, "hostname": hostname, "slurm_version": version}
