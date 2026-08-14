"""Snapshot assembly — the one function the app calls on every refresh.

Command budget per refresh (worst case):

* 1 × ``squeue``           — the live queue
* 1 × ``sacct --allocations`` — recent history (skipped when accounting is unavailable)
* 1 × ``sacct`` step query  — peak memory of finished jobs
* 1 × ``sstat``            — live memory of running jobs
* 1 × ``sinfo --version``  — cluster identity (cheap, no controller job scan)

That is a fixed count regardless of how many jobs the user has. Nothing is queried per job,
and log files are read only for running jobs that lack structured progress, capped by
``MAX_LOG_FALLBACK_JOBS`` jobs — at most one read per distinct stream each of them reports.
"""

from __future__ import annotations

import getpass
import os
import socket
from typing import Any, Dict, List, Optional, Sequence

from . import logtail, progress as progress_mod, sacct, sstat, squeue
from .logparse import CONF_HIGH, CONF_LOW, CONF_MEDIUM, parse_log_lines
from .protocol import (
    AGENT_VERSION,
    SCHEMA_VERSION,
    STATE_CANCELLED,
    STATE_COMPLETED,
    STATE_COMPLETING,
    STATE_PENDING,
    STATE_PREEMPTED,
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
#: The same, for jobs that have already finished. Much smaller: a day of history routinely holds
#: a hundred-plus jobs, their logs never change again, and only the newest few are being looked
#: at. This is a fixed per-poll cost, not one that grows with how long the history window is.
MAX_FINISHED_LOG_FALLBACK_JOBS = 6
LOG_FALLBACK_WINDOW_BYTES = 64 * 1024
LOG_FALLBACK_LINES = 120

#: Which parsed reading wins when both of a job's streams contain one. Confidence first: a
#: labelled ``Epoch 5/10`` in one stream should not lose to a bare ``3/4`` that happens to sit in
#: a file written a second later.
_CONFIDENCE_RANK = {CONF_LOW: 0, CONF_MEDIUM: 1, CONF_HIGH: 2}

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
    """Sniff the tail of the log for jobs that have no structured progress.

    Two groups are read, under separate budgets:

    * jobs still on the cluster (``RUNNING`` or ``COMPLETING``) — the live bar. ``COMPLETING``
      is included because a job that spends a minute in that state used to have its progress
      bar blink out while still displayed under "Running";
    * the most recently finished jobs — so "stopped at epoch 812/1000" survives the moment the
      job leaves the queue. Without this, log-derived progress is discarded exactly when the
      question "how far did it get?" starts to matter, and the answer is only ever available to
      workloads that use the ``slurmbar_progress`` SDK.

    The finished group is capped tightly and sorted newest-first: a day of accounting history
    can hold hundreds of jobs, and reading every one of their logs on every poll is not a
    trade worth making for output nobody is looking at.

    Both reported streams are inspected, not just stdout. tqdm — the most widely deployed
    progress bar in the ecosystem this tool exists for — writes to stderr by default, so a
    stdout-only fallback misses the single most common case it was built to catch.
    """
    live_states = (STATE_RUNNING, STATE_COMPLETING)
    candidates = [
        job
        for job in jobs
        if job["state"] in live_states and job.get("progress") is None and _log_stream_paths(job)
    ]
    finished = [
        job
        for job in jobs
        if job["state"] not in live_states
        and job["state"] != STATE_PENDING
        and job.get("progress") is None
        and _log_stream_paths(job)
    ]
    finished.sort(key=lambda job: job.get("end_time") or "", reverse=True)
    candidates = candidates[:MAX_LOG_FALLBACK_JOBS] + finished[:MAX_FINISHED_LOG_FALLBACK_JOBS]

    missing_path = [
        job
        for job in jobs
        if job["state"] == STATE_RUNNING
        and job.get("progress") is None
        and not _log_stream_paths(job)
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

    for job in candidates:
        best_rank: Optional[tuple] = None
        best_progress: Optional[Dict[str, Any]] = None
        denied: Optional[str] = None

        # stdout first, so it wins a tie; index breaks ties in favour of the earlier stream.
        for index, path in enumerate(_log_stream_paths(job)):
            tail = logtail.read_tail(
                path,
                max_lines=LOG_FALLBACK_LINES,
                window_bytes=LOG_FALLBACK_WINDOW_BYTES,
            )
            if not tail.ok:
                if tail.error_kind == "permission" and denied is None:
                    denied = tail.path
                continue
            parsed = parse_log_lines(tail.lines)
            if parsed is None:
                continue
            rank = (
                _CONFIDENCE_RANK.get(parsed.confidence, 0),
                tail.modified_at or 0.0,
                -index,
            )
            if best_rank is None or rank > best_rank:
                best_rank = rank
                best_progress = parsed.to_progress_json(iso_utc(_from_epoch(tail.modified_at)))

        if best_progress is not None:
            job["progress"] = best_progress
        elif denied is not None:
            # Only worth reporting when it actually cost the user a progress bar: a job whose
            # stderr is unreadable but whose stdout parsed fine has lost nothing.
            warnings.add(
                W.LOG_UNREADABLE,
                f"Permission denied reading the log for job {job['job_id']}.",
                severity="info",
                detail=denied,
                job_id=job["job_id"],
            )


def _log_stream_paths(job: Dict[str, Any]) -> List[str]:
    """The distinct log paths reported for a job, stdout first.

    Slurm reports the same file for both streams whenever a batch script was submitted without
    ``--error``, which is the common case; reading it twice would double the I/O budget for no
    new information.
    """
    paths: List[str] = []
    seen = set()
    for key in ("stdout_path", "stderr_path"):
        path = job.get(key)
        if not path:
            continue
        normalized = os.path.normpath(path)
        if normalized in seen:
            continue
        seen.add(normalized)
        paths.append(path)
    return paths


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
        "cancelled_recently": 0,
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
        elif state in (STATE_CANCELLED, STATE_PREEMPTED):
            # Counted separately rather than not at all. A cancelled job is neither a success
            # nor a failure, and leaving it out of every bucket made the totals understate the
            # history the app was displaying.
            summary["cancelled_recently"] += 1
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
