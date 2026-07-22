"""``sacct`` collection: recent job history and completed-job memory accounting.

Two batched calls at most, never one per job:

1. ``-X`` (allocations only) for the job-level record;
2. an optional step-level call whose ``MaxRSS`` values are folded back onto their parent job.

Output is parsed from ``-P`` (parsable, no padding) with the free-text ``JobName`` placed last
so a ``|`` inside a job name cannot shift any other field. Human-formatted tables are never
parsed.
"""

from __future__ import annotations

import re
from typing import Any, Dict, Iterable, List, Optional, Tuple

from .protocol import (
    MEM_PEAK_RSS_PER_STEP,
    MEM_REQUESTED_PER_CPU,
    MEM_REQUESTED_PER_NODE,
    MEM_REQUESTED_TOTAL,
    MEM_UNAVAILABLE,
    WarningCollector,
    W,
    empty_resources,
)
from .runner import CommandRunner
from .squeue import _gpu_count, expand_node_list
from .states import normalize_state
from .timeutil import (
    elapsed_between,
    is_empty,
    iso_utc,
    parse_duration_seconds,
    parse_exit_code,
    parse_memory,
    parse_slurm_time,
)

# JobName is last: everything before it is delimiter-safe, so a '|' in a job name is harmless.
ALLOC_FIELDS: Tuple[str, ...] = (
    "JobID",
    "State",
    "Partition",
    "User",
    "Account",
    "QOS",
    "Submit",
    "Start",
    "End",
    "ElapsedRaw",
    "TimelimitRaw",
    "ExitCode",
    "NNodes",
    "NCPUS",
    "ReqMem",
    "AllocTRES",
    "NodeList",
    "JobName",
)

STEP_FIELDS: Tuple[str, ...] = ("JobID", "MaxRSS", "MaxVMSize", "TRESUsageInTot")

_ACCOUNTING_DISABLED_HINTS = (
    "accounting_storage",
    "accounting storage is disabled",
    "slurm accounting storage is disabled",
    "no accounting",
    "accounting disabled",
)

_TRES_GPUMEM_RE = re.compile(r"gres/gpumem[^=]*=([0-9.]+[KMGTPE]?)", re.IGNORECASE)
_TRES_GPUUTIL_RE = re.compile(r"gres/gpuutil[^=]*=([0-9.]+)", re.IGNORECASE)
_TRES_MEM_RE = re.compile(r"(?:^|,)mem=([0-9.]+[KMGTPE]?)", re.IGNORECASE)


def is_available(runner: CommandRunner) -> bool:
    return runner.which("sacct") is not None


def collect_history(
    runner: CommandRunner,
    user: Optional[str],
    history_hours: int,
    warnings: WarningCollector,
    timeout: float = 20.0,
    with_step_memory: bool = True,
) -> List[Dict[str, Any]]:
    """Return normalized job dicts for jobs that ended within ``history_hours``."""
    if not is_available(runner):
        warnings.add(
            W.SACCT_UNAVAILABLE,
            "sacct is not available; recently finished jobs cannot be shown.",
            severity="info",
            detail="Slurm accounting (slurmdbd) may not be configured on this cluster.",
        )
        return []

    argv = [
        "sacct",
        "--noheader",
        "--parsable2",
        "--allocations",
        f"--starttime=now-{int(history_hours)}hours",
        "--endtime=now",
        "--format=" + ",".join(ALLOC_FIELDS),
    ]
    if user:
        argv += ["--user", user]

    result = runner.run(argv, timeout=timeout)
    if result.timed_out:
        warnings.add(W.COMMAND_TIMEOUT, "sacct timed out; job history is unavailable.")
        return []
    if not result.ok:
        stderr = (result.stderr or "").lower()
        if any(hint in stderr for hint in _ACCOUNTING_DISABLED_HINTS):
            warnings.add(
                W.ACCOUNTING_DISABLED,
                "Slurm accounting is disabled; finished jobs and memory accounting are unavailable.",
                severity="info",
                detail=result.stderr.strip()[:400] or None,
            )
        else:
            warnings.add(
                W.SACCT_FAILED,
                "sacct failed; recently finished jobs are unavailable.",
                detail=result.failure_summary(),
            )
        return []

    jobs = parse_sacct_allocations(result.stdout, warnings)

    if with_step_memory and jobs:
        step_memory = _collect_step_memory(runner, user, history_hours, warnings, timeout)
        _apply_step_memory(jobs, step_memory)

    return jobs


def parse_sacct_allocations(payload: str, warnings: WarningCollector) -> List[Dict[str, Any]]:
    jobs: List[Dict[str, Any]] = []
    field_count = len(ALLOC_FIELDS)
    for line in payload.splitlines():
        if not line.strip():
            continue
        parts = line.split("|", field_count - 1)
        if len(parts) != field_count:
            warnings.add(
                W.PARTIAL_DATA,
                "An sacct line had an unexpected field count and was skipped.",
                detail=f"expected {field_count} fields, got {len(parts)}",
            )
            continue
        row = dict(zip(ALLOC_FIELDS, (p.strip() for p in parts)))
        try:
            job = _job_from_sacct_row(row)
        except Exception as exc:
            warnings.add(
                W.PARTIAL_DATA,
                "An sacct line could not be parsed and was skipped.",
                detail=f"{type(exc).__name__}: {exc}",
            )
            continue
        if job is not None:
            jobs.append(job)
    return jobs


def _job_from_sacct_row(row: Dict[str, str]) -> Optional[Dict[str, Any]]:
    job_id = row.get("JobID", "").strip()
    if not job_id:
        return None
    # `--allocations` should exclude steps, but be defensive about builds that do not.
    if "." in job_id:
        return None

    array_job_id: Optional[str] = None
    array_task_id: Optional[str] = None
    if "_" in job_id:
        head, _, tail = job_id.partition("_")
        if head.isdigit():
            array_job_id = head
            array_task_id = tail if tail.isdigit() else tail or None

    state, state_raw = normalize_state(row.get("State"))
    submit = parse_slurm_time(row.get("Submit"))
    start = parse_slurm_time(row.get("Start"))
    end = parse_slurm_time(row.get("End"))

    elapsed = parse_duration_seconds(row.get("ElapsedRaw"))
    if elapsed is None:
        elapsed = elapsed_between(start, end)

    time_limit = parse_duration_seconds(row.get("TimelimitRaw"))
    if time_limit is not None:
        time_limit *= 60  # TimelimitRaw is minutes

    exit_code, signal = parse_exit_code(row.get("ExitCode"))

    resources = empty_resources()
    req_mem = parse_memory(row.get("ReqMem"), default_unit="M")
    if req_mem.bytes:
        resources["memory_limit_bytes"] = req_mem.bytes
        resources["memory_limit_semantics"] = {
            "c": MEM_REQUESTED_PER_CPU,
            "n": MEM_REQUESTED_PER_NODE,
        }.get(req_mem.per or "", MEM_REQUESTED_TOTAL)
    else:
        resources["memory_limit_semantics"] = MEM_UNAVAILABLE

    return {
        "job_id": job_id,
        # sacct reports array tasks in "<parent>_<task>" form, so no separate id is needed.
        "slurm_job_id": None,
        "array_job_id": array_job_id,
        "array_task_id": array_task_id,
        "name": row.get("JobName") or job_id,
        "user": _clean(row.get("User")),
        "account": _clean(row.get("Account")),
        "partition": _clean(row.get("Partition")),
        "qos": _clean(row.get("QOS")),
        "state": state,
        "state_raw": state_raw,
        "reason": None,
        "submit_time": iso_utc(submit),
        "start_time": iso_utc(start),
        "end_time": iso_utc(end),
        "elapsed_seconds": elapsed,
        "time_limit_seconds": time_limit,
        "nodes": expand_node_list(_clean(row.get("NodeList"))),
        "node_count": _int_or_none(row.get("NNodes")),
        "cpus": _int_or_none(row.get("NCPUS")),
        "gpus": _gpu_count(_clean(row.get("AllocTRES"))),
        "work_dir": None,
        "stdout_path": None,
        "stderr_path": None,
        "exit_code": exit_code,
        "signal": signal,
        "source": "sacct",
        "resources": resources,
        "progress": None,
    }


# ---------------------------------------------------------------------------------------------
# Step-level memory
# ---------------------------------------------------------------------------------------------


def _collect_step_memory(
    runner: CommandRunner,
    user: Optional[str],
    history_hours: int,
    warnings: WarningCollector,
    timeout: float,
) -> Dict[str, Dict[str, Any]]:
    argv = [
        "sacct",
        "--noheader",
        "--parsable2",
        f"--starttime=now-{int(history_hours)}hours",
        "--endtime=now",
        "--format=" + ",".join(STEP_FIELDS),
    ]
    if user:
        argv += ["--user", user]
    result = runner.run(argv, timeout=timeout)
    if not result.ok:
        warnings.add(
            W.MEMORY_UNAVAILABLE,
            "Step-level memory accounting could not be read for finished jobs.",
            severity="info",
            detail=result.failure_summary(),
        )
        return {}
    return parse_sacct_steps(result.stdout)


def parse_sacct_steps(payload: str) -> Dict[str, Dict[str, Any]]:
    """Fold step rows into ``{base_job_id: {"memory_used_bytes": …, "gpu_…": …}}``.

    ``MaxRSS`` is the peak resident set of the *largest single step*, not the live total for
    the job. That distinction travels with the value as ``peak_rss_per_step``.
    """
    peaks: Dict[str, Dict[str, Any]] = {}
    for line in payload.splitlines():
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < len(STEP_FIELDS):
            continue
        row = dict(zip(STEP_FIELDS, parts))
        step_id = row["JobID"]
        base = step_id.split(".", 1)[0]
        if not base:
            continue
        bucket = peaks.setdefault(
            base,
            {
                "memory_used_bytes": None,
                "gpu_memory_used_bytes": None,
                "gpu_utilization_percent": None,
            },
        )

        max_rss = parse_memory(row.get("MaxRSS"), default_unit="K").bytes
        tres = row.get("TRESUsageInTot") or ""
        if max_rss is None:
            tres_mem = _TRES_MEM_RE.search(tres)
            if tres_mem:
                max_rss = parse_memory(tres_mem.group(1), default_unit="K").bytes
        if max_rss is not None:
            current = bucket["memory_used_bytes"]
            bucket["memory_used_bytes"] = max_rss if current is None else max(current, max_rss)

        gpu_mem = _TRES_GPUMEM_RE.search(tres)
        if gpu_mem:
            parsed = parse_memory(gpu_mem.group(1), default_unit="M").bytes
            if parsed is not None:
                current = bucket["gpu_memory_used_bytes"]
                bucket["gpu_memory_used_bytes"] = (
                    parsed if current is None else max(current, parsed)
                )

        gpu_util = _TRES_GPUUTIL_RE.search(tres)
        if gpu_util:
            try:
                value = max(0.0, min(100.0, float(gpu_util.group(1))))
            except ValueError:
                value = None
            if value is not None:
                current = bucket["gpu_utilization_percent"]
                bucket["gpu_utilization_percent"] = (
                    value if current is None else max(current, value)
                )
    return peaks


def _apply_step_memory(jobs: Iterable[Dict[str, Any]], peaks: Dict[str, Dict[str, Any]]) -> None:
    for job in jobs:
        bucket = peaks.get(job["job_id"])
        if bucket is None:
            continue
        resources = job["resources"]
        if bucket.get("memory_used_bytes") is not None:
            resources["memory_used_bytes"] = bucket["memory_used_bytes"]
            resources["memory_semantics"] = MEM_PEAK_RSS_PER_STEP
        if bucket.get("gpu_memory_used_bytes") is not None:
            resources["gpu_memory_used_bytes"] = bucket["gpu_memory_used_bytes"]
        if bucket.get("gpu_utilization_percent") is not None:
            resources["gpu_utilization_percent"] = bucket["gpu_utilization_percent"]


def _clean(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    text = value.strip()
    return None if is_empty(text) else text


def _int_or_none(value: Optional[str]) -> Optional[int]:
    if is_empty(value):
        return None
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None
