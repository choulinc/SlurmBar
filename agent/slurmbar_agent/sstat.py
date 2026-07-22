"""``sstat`` collection: live resource usage for *running* jobs.

One batched call for all running job ids. ``sstat`` only reports jobs the caller owns and only
while a step is active, so failures here are routine and always nonfatal.

``MaxRSS`` from ``sstat`` is the peak resident set of a step so far — not the job's live total
memory. It is exported as ``peak_rss`` so the UI can label it correctly.
"""

from __future__ import annotations

import re
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

from .protocol import MEM_PEAK_RSS, WarningCollector, W
from .runner import CommandRunner
from .timeutil import parse_memory
from .validate import base_job_id

FIELDS: Tuple[str, ...] = ("JobID", "MaxRSS", "AveRSS", "MaxVMSize", "TRESUsageInTot")

MAX_BATCH = 200

_TRES_GPUMEM_RE = re.compile(r"gres/gpumem[^=]*=([0-9.]+[KMGTPE]?)", re.IGNORECASE)
_TRES_GPUUTIL_RE = re.compile(r"gres/gpuutil[^=]*=([0-9.]+)", re.IGNORECASE)


def is_available(runner: CommandRunner) -> bool:
    return runner.which("sstat") is not None


def collect_live_usage(
    runner: CommandRunner,
    job_ids: Sequence[str],
    warnings: WarningCollector,
    timeout: float = 15.0,
) -> Dict[str, Dict[str, Any]]:
    """Return ``{job_id: {"memory_used_bytes": …, …}}`` for running jobs.

    ``job_ids`` must already be validated. An empty result is normal, not an error.
    """
    if not job_ids:
        return {}
    if not is_available(runner):
        warnings.add(
            W.SSTAT_UNAVAILABLE,
            "sstat is not available; live memory usage for running jobs cannot be shown.",
            severity="info",
        )
        return {}

    unique = list(dict.fromkeys(job_ids))[:MAX_BATCH]
    argv = [
        "sstat",
        "--noheader",
        "--parsable2",
        "--allsteps",
        "--jobs=" + ",".join(unique),
        "--format=" + ",".join(FIELDS),
    ]
    result = runner.run(argv, timeout=timeout)
    if result.timed_out:
        warnings.add(
            W.COMMAND_TIMEOUT,
            "sstat timed out; live memory usage is unavailable this refresh.",
            severity="info",
        )
        return {}
    if not result.ok:
        # Very common and benign: no step is active yet, or the batch step has not registered.
        warnings.add(
            W.SSTAT_FAILED,
            "Live memory usage is unavailable for running jobs.",
            severity="info",
            detail=result.failure_summary(),
        )
        return {}
    return parse_sstat(result.stdout)


def parse_sstat(payload: str) -> Dict[str, Dict[str, Any]]:
    usage: Dict[str, Dict[str, Any]] = {}
    for line in payload.splitlines():
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < len(FIELDS):
            continue
        row = dict(zip(FIELDS, parts))
        step_id = row.get("JobID") or ""
        base = step_id.split(".", 1)[0]
        if not base:
            continue
        bucket = usage.setdefault(
            base,
            {
                "memory_used_bytes": None,
                "memory_semantics": MEM_PEAK_RSS,
                "gpu_memory_used_bytes": None,
                "gpu_utilization_percent": None,
            },
        )

        max_rss = parse_memory(row.get("MaxRSS"), default_unit="K").bytes
        if max_rss is not None:
            current = bucket["memory_used_bytes"]
            bucket["memory_used_bytes"] = max_rss if current is None else max(current, max_rss)

        tres = row.get("TRESUsageInTot") or ""
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
                bucket["gpu_utilization_percent"] = value
    return usage


def apply_live_usage(jobs: Iterable[Dict[str, Any]], usage: Dict[str, Dict[str, Any]]) -> None:
    """Merge sstat results onto matching jobs, keeping memory semantics honest."""
    for job in jobs:
        # Lookup order matters. sstat answers an array query with the tasks' underlying job
        # ids, so matching only on the display id would miss every task and then fall through
        # to the array parent, giving every task in the array the parent's memory figure.
        bucket = usage.get(job["job_id"])
        if bucket is None and job.get("slurm_job_id"):
            bucket = usage.get(job["slurm_job_id"])
        if bucket is None and not job.get("slurm_job_id"):
            bucket = usage.get(base_job_id_safe(job["job_id"]))
        if not bucket:
            continue
        resources = job["resources"]
        if bucket.get("memory_used_bytes") is not None:
            resources["memory_used_bytes"] = bucket["memory_used_bytes"]
            resources["memory_semantics"] = MEM_PEAK_RSS
        if bucket.get("gpu_memory_used_bytes") is not None:
            resources["gpu_memory_used_bytes"] = bucket["gpu_memory_used_bytes"]
        if bucket.get("gpu_utilization_percent") is not None:
            resources["gpu_utilization_percent"] = bucket["gpu_utilization_percent"]


def base_job_id_safe(job_id: str) -> str:
    try:
        return base_job_id(job_id)
    except Exception:  # pragma: no cover - job ids reaching here are already validated
        return job_id


def running_job_ids(jobs: Iterable[Dict[str, Any]]) -> List[str]:
    return [job["job_id"] for job in jobs if job.get("state") == "RUNNING"]
