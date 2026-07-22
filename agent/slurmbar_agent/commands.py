"""On-demand commands: single-job detail, bounded log tails, and guarded cancellation."""

from __future__ import annotations

import os
from typing import Any, Dict, List, Optional

from . import logtail, progress as progress_mod, scontrol, snapshot as snapshot_mod, sstat, squeue
from .errors import NotFound
from .protocol import AGENT_VERSION, SCHEMA_VERSION, STATE_RUNNING, WarningCollector, W
from .runner import CommandRunner
from .timeutil import iso_utc, utc_now
from .validate import validate_job_id, validate_stream

MAX_LOG_LINES = 2000


# ---------------------------------------------------------------------------------------------
# job
# ---------------------------------------------------------------------------------------------


def job_detail(
    runner: CommandRunner,
    job_id: str,
    progress_dir: Optional[str] = None,
    stale_seconds: int = progress_mod.DEFAULT_STALE_SECONDS,
    history_hours: int = 48,
    timeout: float = 15.0,
) -> Dict[str, Any]:
    """Full detail for one job. Used only when the user opens a job, never during polling."""
    job_id = validate_job_id(job_id)
    warnings = WarningCollector()
    now = utc_now()

    job = _find_job(runner, job_id, history_hours, warnings, timeout)
    if job is None:
        raise NotFound(f"Job {job_id} was not found in the queue or in accounting.")

    # Resolve log paths and working directory; squeue's text fallback cannot supply them.
    fields = scontrol.show_job(runner, job_id, timeout=timeout)
    if fields:
        paths = scontrol.log_paths(fields)
        for key in ("stdout_path", "stderr_path", "work_dir"):
            if job.get(key) is None and paths.get(key):
                job[key] = paths[key]

    if job["state"] == STATE_RUNNING:
        usage = sstat.collect_live_usage(runner, [job_id], warnings, timeout=timeout)
        sstat.apply_live_usage([job], usage)

    resolved_dir = os.path.expanduser(progress_dir or progress_mod.default_state_dir())
    structured = progress_mod.load_all(
        resolved_dir, [job_id], warnings, stale_seconds=stale_seconds, now=now
    )
    if job_id in structured:
        job["progress"] = structured[job_id]
    elif job["state"] == STATE_RUNNING and job.get("stdout_path"):
        snapshot_mod._apply_log_fallback([job], warnings)

    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": iso_utc(now),
        "agent_version": AGENT_VERSION,
        "job": job,
        "warnings": warnings.to_json(),
    }


def _find_job(
    runner: CommandRunner,
    job_id: str,
    history_hours: int,
    warnings: WarningCollector,
    timeout: float,
) -> Optional[Dict[str, Any]]:
    if runner.which("squeue") is not None:
        argv = ["squeue", "--noheader", "--jobs", job_id, "-o", squeue._TEXT_FORMAT]
        result = runner.run(argv, timeout=timeout)
        if result.ok and result.stdout.strip():
            found = squeue.parse_squeue_text(result.stdout, warnings)
            if found:
                return found[0]

    if runner.which("sacct") is not None:
        from . import sacct as sacct_mod

        argv = [
            "sacct",
            "--noheader",
            "--parsable2",
            "--allocations",
            "--jobs",
            job_id,
            "--format=" + ",".join(sacct_mod.ALLOC_FIELDS),
        ]
        result = runner.run(argv, timeout=timeout)
        if result.ok and result.stdout.strip():
            found = sacct_mod.parse_sacct_allocations(result.stdout, warnings)
            if found:
                job = found[0]
                steps_argv = [
                    "sacct",
                    "--noheader",
                    "--parsable2",
                    "--jobs",
                    job_id,
                    "--format=" + ",".join(sacct_mod.STEP_FIELDS),
                ]
                steps = runner.run(steps_argv, timeout=timeout)
                if steps.ok:
                    sacct_mod._apply_step_memory([job], sacct_mod.parse_sacct_steps(steps.stdout))
                return job
    return None


# ---------------------------------------------------------------------------------------------
# logs
# ---------------------------------------------------------------------------------------------


def read_logs(
    runner: CommandRunner,
    job_id: str,
    stream: str = "stdout",
    lines: int = 200,
    path_override: Optional[str] = None,
    timeout: float = 12.0,
) -> Dict[str, Any]:
    """Return a bounded tail of a job's stdout or stderr. Reads on demand only."""
    job_id = validate_job_id(job_id)
    stream = validate_stream(stream)
    lines = max(1, min(int(lines), MAX_LOG_LINES))
    warnings = WarningCollector()

    path: Optional[str] = None
    if path_override:
        # Only honoured when the caller already knows the path from a previous snapshot; it is
        # never derived from untrusted input inside the agent.
        path = os.path.expanduser(path_override)
    else:
        fields = scontrol.show_job(runner, job_id, timeout=timeout)
        if fields:
            paths = scontrol.log_paths(fields)
            path = paths.get("stdout_path") if stream == "stdout" else paths.get("stderr_path")
            if stream == "stderr" and not path:
                # Slurm reports StdErr == StdOut when the job did not separate the streams.
                path = None

    if not path:
        warnings.add(
            W.LOG_PATH_UNKNOWN,
            f"SlurmBar could not determine the {stream} path for job {job_id}.",
            detail=(
                "Slurm only reports log paths while a job is known to the controller. For a "
                "finished job, open the file directly on the cluster."
            ),
            job_id=job_id,
        )
        return _logs_payload(job_id, stream, None, logtail.TailResult(path=None), warnings)

    tail = logtail.read_tail(path, max_lines=lines)
    if not tail.ok:
        code = W.LOG_UNREADABLE if tail.error_kind != "missing" else W.LOG_PATH_UNKNOWN
        warnings.add(code, tail.error or "The log file could not be read.", detail=path, job_id=job_id)
    return _logs_payload(job_id, stream, path, tail, warnings)


def _logs_payload(
    job_id: str,
    stream: str,
    path: Optional[str],
    tail: logtail.TailResult,
    warnings: WarningCollector,
) -> Dict[str, Any]:
    modified = None
    if tail.modified_at is not None:
        from datetime import datetime, timezone

        modified = iso_utc(datetime.fromtimestamp(tail.modified_at, tz=timezone.utc))
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": iso_utc(utc_now()),
        "job_id": job_id,
        "stream": stream,
        "path": path,
        "lines": tail.lines,
        "bytes_read": tail.bytes_read,
        "file_size_bytes": tail.file_size_bytes,
        "truncated": tail.truncated,
        "modified_at": modified,
        "warnings": warnings.to_json(),
    }


# ---------------------------------------------------------------------------------------------
# cancel  (destructive — never called automatically, never exercised by the test suite)
# ---------------------------------------------------------------------------------------------


def cancel_job(runner: CommandRunner, job_id: str, timeout: float = 20.0) -> Dict[str, Any]:
    """Run ``scancel`` for exactly one validated job id.

    The id is validated before it becomes an argv element, and no shell is involved anywhere,
    so nothing in the id can be interpreted as a command. The app requires an explicit
    confirmation before this is ever reached.
    """
    job_id = validate_job_id(job_id)

    if runner.which("scancel") is None:
        return {
            "schema_version": SCHEMA_VERSION,
            "generated_at": iso_utc(utc_now()),
            "job_id": job_id,
            "ok": False,
            "exit_code": None,
            "message": "scancel is not available on this login node.",
            "stderr": None,
        }

    result = runner.run(["scancel", "--verbose", job_id], timeout=timeout)
    message: Optional[str]
    if result.timed_out:
        message = "scancel timed out. The job may or may not have been cancelled."
    elif result.ok:
        message = f"Cancellation requested for job {job_id}."
    else:
        message = result.failure_summary()

    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": iso_utc(utc_now()),
        "job_id": job_id,
        "ok": bool(result.ok),
        "exit_code": None if result.timed_out else result.returncode,
        "message": message,
        "stderr": (result.stderr or "").strip()[:2000] or None,
    }
