"""On-demand GPU telemetry collected inside running Slurm allocations.

This is deliberately not part of the normal snapshot: starting one overlapping ``srun`` step
per job is much more expensive than querying the controller. The app calls this module only
while the user is looking at the GPU page.
"""

from __future__ import annotations

import csv
import io
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List, Optional, Sequence

from . import squeue
from .errors import InvalidArgument
from .protocol import AGENT_VERSION, SCHEMA_VERSION, WarningCollector, W
from .runner import CommandResult, CommandRunner
from .timeutil import iso_utc, utc_now
from .validate import validate_job_id

MAX_GPU_JOBS = 64
MAX_PARALLEL_SRUN = 4
MAX_NODES_PER_JOB = 64
MAX_TOTAL_NODES = 256
NVIDIA_QUERY = "index,name,utilization.gpu,memory.used,memory.total,power.draw"
_GPU_SCRIPT = (
    'node="${SLURMD_NODENAME:-${HOSTNAME:-unknown}}"; '
    'output="$(nvidia-smi "$@")" || exit $?; '
    'printf "%s\\n" "$output" | while IFS= read -r line; do '
    'printf "%s|%s\\n" "$node" "$line"; done'
)


def collect_gpu_status(
    runner: CommandRunner,
    job_ids: Sequence[str],
    timeout: float = 15.0,
) -> Dict[str, Any]:
    """Run one bounded, overlapping ``nvidia-smi`` step for each requested allocation."""
    validated: List[str] = []
    seen = set()
    for raw in job_ids:
        job_id = validate_job_id(raw)
        if job_id not in seen:
            validated.append(job_id)
            seen.add(job_id)
    if len(validated) > MAX_GPU_JOBS:
        raise InvalidArgument(f"too many GPU jobs (max {MAX_GPU_JOBS})")

    warnings = WarningCollector()
    if runner.which("srun") is None:
        warnings.add(
            W.GPU_METRICS_UNAVAILABLE,
            "srun is not available on this login node.",
            detail="GPU telemetry must run inside each job allocation.",
        )
        results = [_failed_job(job_id, "srun is not available.") for job_id in validated]
    else:
        allocations = _allocation_info(runner, validated, timeout)
        total_nodes = sum(info[0] for info in allocations.values())
        if total_nodes > MAX_TOTAL_NODES:
            raise InvalidArgument(
                f"GPU query spans {total_nodes} nodes; the safety limit is {MAX_TOTAL_NODES}"
            )

        results_by_id: Dict[str, Dict[str, Any]] = {}
        runnable = []
        for job_id in validated:
            info = allocations.get(job_id)
            if info is None:
                results_by_id[job_id] = _failed_job(
                    job_id,
                    "Could not verify this job's node and GPU allocation. It may have ended.",
                )
            else:
                runnable.append((job_id, info[0], info[1]))

        workers = min(MAX_PARALLEL_SRUN, max(1, len(runnable)))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {
                pool.submit(_collect_one, runner, job_id, nodes, gpus_per_node, timeout): job_id
                for job_id, nodes, gpus_per_node in runnable
            }
            for future in as_completed(futures):
                job_id = futures[future]
                try:
                    results_by_id[job_id] = future.result()
                except Exception as exc:  # one allocation must not blank the whole page
                    results_by_id[job_id] = _failed_job(
                        job_id, f"GPU query failed: {type(exc).__name__}: {exc}"
                    )
        results = [results_by_id[job_id] for job_id in validated]

    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": iso_utc(utc_now()),
        "agent_version": AGENT_VERSION,
        "jobs": results,
        "warnings": warnings.to_json(),
    }


def _allocation_info(
    runner: CommandRunner, job_ids: Sequence[str], timeout: float
) -> Dict[str, tuple[int, int]]:
    """Return verified ``node_count, GPUs_per_node`` for the requested running jobs."""
    if not job_ids or runner.which("squeue") is None:
        return {}
    result = runner.run(
        [
            "squeue",
            "--noheader",
            "--jobs",
            ",".join(job_ids),
            "--format=%i|%D|%b",
        ],
        timeout=timeout,
    )
    if not result.ok:
        return {}

    requested = set(job_ids)
    allocations: Dict[str, tuple[int, int]] = {}
    for line in result.stdout.splitlines():
        parts = [part.strip() for part in line.split("|", 2)]
        if len(parts) != 3 or parts[0] not in requested:
            continue
        try:
            node_count = int(parts[1])
        except ValueError:
            continue
        gpus_per_node = squeue._gpu_count(parts[2])
        if not (1 <= node_count <= MAX_NODES_PER_JOB):
            continue
        if gpus_per_node is None or not (1 <= gpus_per_node <= 128):
            continue
        allocations[parts[0]] = (node_count, gpus_per_node)
    return allocations


def _collect_one(
    runner: CommandRunner,
    job_id: str,
    node_count: int,
    expected_gpus_per_node: int,
    timeout: float,
) -> Dict[str, Any]:
    argv = [
        "srun",
        f"--jobid={job_id}",
        "--overlap",
        f"--nodes={node_count}",
        f"--ntasks={node_count}",
        "--ntasks-per-node=1",
        "--kill-on-bad-exit=1",
        "/bin/sh",
        "-c",
        _GPU_SCRIPT,
        "slurmbar-nvidia-smi",
        f"--query-gpu={NVIDIA_QUERY}",
        "--format=csv,noheader,nounits",
    ]
    result = runner.run(argv, timeout=timeout)
    if not result.ok:
        return _failed_job(job_id, _failure_message(result))

    devices = _parse_nvidia_smi(result.stdout)
    if not devices:
        return _failed_job(job_id, "nvidia-smi returned no GPU devices.")

    counts = Counter(device["node"] for device in devices)
    if any(count > expected_gpus_per_node for count in counts.values()):
        return _failed_job(
            job_id,
            "nvidia-smi exposed more GPUs than Slurm allocated. Data was hidden to avoid "
            "showing devices that may belong to another job.",
        )

    expected_total = node_count * expected_gpus_per_node
    message = None
    if len(counts) != node_count or len(devices) != expected_total:
        message = (
            f"Partial reading: received {len(devices)} of {expected_total} allocated GPUs "
            f"from {len(counts)} of {node_count} nodes."
        )
    return {"job_id": job_id, "ok": True, "message": message, "gpus": devices}


def _parse_nvidia_smi(text: str) -> List[Dict[str, Any]]:
    devices: List[Dict[str, Any]] = []
    for raw_line in io.StringIO(text):
        if "|" not in raw_line:
            continue
        raw_node, csv_line = raw_line.split("|", 1)
        rows = list(csv.reader([csv_line], skipinitialspace=True))
        if not rows:
            continue
        row = rows[0]
        if not row or all(not value.strip() for value in row):
            continue
        if len(row) != 6:
            continue
        node = raw_node.strip()[:160]
        index = _integer(row[0])
        if not node or index is None:
            continue
        devices.append(
            {
                "node": node,
                "index": index,
                "name": row[1].strip()[:160] or "GPU",
                "utilization_percent": _number(row[2]),
                "memory_used_mib": _number(row[3]),
                "memory_total_mib": _number(row[4]),
                "power_draw_watts": _number(row[5]),
            }
        )
    return devices


def _number(value: str) -> Optional[float]:
    text = value.strip()
    if not text or text.lower() in {"n/a", "[not supported]", "not supported"}:
        return None
    try:
        number = float(text)
    except ValueError:
        return None
    return number if number >= 0 else None


def _integer(value: str) -> Optional[int]:
    number = _number(value)
    if number is None or not number.is_integer():
        return None
    return int(number)


def _failure_message(result: CommandResult) -> str:
    if result.timed_out:
        return "GPU query timed out. The allocation may be busy or ending."
    detail = (result.stderr or result.stdout or "").strip().splitlines()
    if detail:
        return detail[0][:500]
    return f"srun exited with status {result.returncode}."


def _failed_job(job_id: str, message: str) -> Dict[str, Any]:
    return {"job_id": job_id, "ok": False, "message": message[:500], "gpus": []}
