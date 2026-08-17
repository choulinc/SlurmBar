"""Reading structured progress files written by ``slurmbar_progress``.

Layout on the shared filesystem::

    <state_dir>/<job_id>/status.json

The agent reads only inside the configured state directory, only files named ``status.json``,
and only up to a small size cap. Nothing else in the user's account is touched.

An array task ``123_4`` looks first at its own directory, then falls back to the array parent
``123`` — a reporter that only saw ``SLURM_ARRAY_JOB_ID`` still gets matched.
"""

from __future__ import annotations

import json
import os
import stat
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, List, Optional

from .protocol import (
    PROGRESS_SOURCE_STRUCTURED,
    SCHEMA_VERSION,
    WarningCollector,
    W,
)
from .timeutil import iso_utc, parse_slurm_time, utc_now
from .validate import base_job_id, is_valid_job_id

STATUS_FILENAME = "status.json"
MAX_STATUS_BYTES = 256 * 1024
DEFAULT_STALE_SECONDS = 180
MAX_METRICS = 64
MAX_METRIC_KEY_CHARS = 64
MAX_METRIC_STRING_CHARS = 200


def default_state_dir() -> str:
    override = os.environ.get("SLURMBAR_STATE_DIR")
    if override:
        return os.path.expanduser(override)
    xdg = os.environ.get("XDG_STATE_HOME")
    if xdg:
        return os.path.join(os.path.expanduser(xdg), "slurmbar", "jobs")
    return os.path.expanduser("~/.local/state/slurmbar/jobs")


@dataclass
class ProgressRecord:
    job_id: str
    payload: Dict[str, Any]
    path: str


def load_all(
    state_dir: str,
    job_ids: Iterable[str],
    warnings: WarningCollector,
    stale_seconds: int = DEFAULT_STALE_SECONDS,
    now: Optional[datetime] = None,
) -> Dict[str, Dict[str, Any]]:
    """Return ``{job_id: progress_json}`` for the jobs that have a readable status file."""
    resolved = os.path.expanduser(state_dir)
    wanted = [jid for jid in job_ids if is_valid_job_id(jid)]
    if not wanted:
        return {}

    if not os.path.isdir(resolved):
        warnings.add(
            W.PROGRESS_DIR_MISSING,
            "No structured progress directory was found; epoch/batch details are unavailable.",
            severity="info",
            detail=(
                f"Looked in {resolved}. Add slurmbar_progress to the workload, or set the "
                "progress directory in SlurmBar settings."
            ),
        )
        return {}

    out: Dict[str, Dict[str, Any]] = {}
    moment = now or utc_now()
    for job_id in wanted:
        record = _read_for_job(resolved, job_id, warnings)
        if record is None:
            continue
        progress = _normalize(record.payload, stale_seconds, moment)
        if progress is None:
            continue
        out[job_id] = progress
        if progress["stale"] and progress.get("completion") == "running":
            warnings.add(
                W.PROGRESS_STALE,
                f"Progress for job {job_id} has not been updated recently.",
                severity="info",
                detail=f"Last update: {progress.get('updated_at')}",
                job_id=job_id,
            )
    return out


def _read_for_job(
    state_dir: str, job_id: str, warnings: WarningCollector
) -> Optional[ProgressRecord]:
    root = os.path.realpath(state_dir)
    candidates: List[str] = [job_id]
    base = base_job_id(job_id)
    if base != job_id:
        candidates.append(base)

    for candidate in candidates:
        job_dir = os.path.join(root, candidate)
        path = os.path.join(job_dir, STATUS_FILENAME)
        directory_fd: Optional[int] = None
        status_fd: Optional[int] = None
        try:
            directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
            directory_flags |= getattr(os, "O_NOFOLLOW", 0)
            directory_fd = os.open(job_dir, directory_flags)

            status_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            status_fd = os.open(STATUS_FILENAME, status_flags, dir_fd=directory_fd)
            metadata = os.fstat(status_fd)
            if not stat.S_ISREG(metadata.st_mode):
                warnings.add(
                    W.PROGRESS_FILE_INVALID,
                    f"Progress path for job {job_id} is not a regular file.",
                    detail=path,
                    job_id=job_id,
                )
                return None
            if metadata.st_size > MAX_STATUS_BYTES:
                warnings.add(
                    W.PROGRESS_FILE_INVALID,
                    f"Progress file for job {job_id} is unexpectedly large and was ignored.",
                    detail=f"{path} is {metadata.st_size} bytes (limit {MAX_STATUS_BYTES}).",
                    job_id=job_id,
                )
                return None

            raw = bytearray()
            while len(raw) <= MAX_STATUS_BYTES:
                chunk = os.read(status_fd, min(64 * 1024, MAX_STATUS_BYTES + 1 - len(raw)))
                if not chunk:
                    break
                raw.extend(chunk)
            if len(raw) > MAX_STATUS_BYTES:
                warnings.add(
                    W.PROGRESS_FILE_INVALID,
                    f"Progress file for job {job_id} grew beyond the size limit and was ignored.",
                    detail=f"{path} exceeds {MAX_STATUS_BYTES} bytes.",
                    job_id=job_id,
                )
                return None
            payload = json.loads(bytes(raw).decode("utf-8", errors="replace"))
        except FileNotFoundError:
            continue
        except json.JSONDecodeError as exc:
            # A torn read is possible in theory; the writer renames atomically, so this
            # usually means a hand-edited or foreign file.
            warnings.add(
                W.PROGRESS_FILE_INVALID,
                f"Progress file for job {job_id} is not valid JSON.",
                detail=str(exc),
                job_id=job_id,
            )
            return None
        except PermissionError:
            warnings.add(
                W.PROGRESS_FILE_INVALID,
                f"Permission denied reading the progress file for job {job_id}.",
                detail=path,
                job_id=job_id,
            )
            return None
        except OSError as exc:
            warnings.add(
                W.PROGRESS_FILE_INVALID,
                f"Could not read the progress file for job {job_id}.",
                detail=str(exc),
                job_id=job_id,
            )
            return None
        finally:
            if status_fd is not None:
                try:
                    os.close(status_fd)
                except OSError:
                    pass
            if directory_fd is not None:
                try:
                    os.close(directory_fd)
                except OSError:
                    pass

        if not isinstance(payload, dict):
            warnings.add(
                W.PROGRESS_FILE_INVALID,
                f"Progress file for job {job_id} is not a JSON object.",
                job_id=job_id,
            )
            return None

        version = payload.get("schema_version")
        if version != SCHEMA_VERSION:
            warnings.add(
                W.PROGRESS_SCHEMA_UNSUPPORTED,
                f"Progress file for job {job_id} uses unsupported schema version {version!r}.",
                detail=f"This agent understands schema_version {SCHEMA_VERSION}.",
                job_id=job_id,
            )
            return None

        return ProgressRecord(job_id=job_id, payload=payload, path=path)
    return None
def _normalize(
    payload: Dict[str, Any], stale_seconds: int, now: datetime
) -> Optional[Dict[str, Any]]:
    updated = parse_slurm_time(payload.get("updated_at"))
    started = parse_slurm_time(payload.get("started_at"))

    current = _number(payload.get("current"))
    total = _number(payload.get("total"))
    percent = None
    if current is not None and total is not None and total > 0:
        percent = round(max(0.0, min(100.0, current / total * 100.0)), 4)

    completion = payload.get("completion")
    if completion not in ("running", "completed", "failed"):
        completion = "running"

    age = (now - updated).total_seconds() if updated else None
    stale = bool(age is not None and age > stale_seconds and completion == "running")
    if updated is None:
        stale = True

    eta = _estimate_eta(current, total, started, updated, completion, stale)

    return {
        "source": PROGRESS_SOURCE_STRUCTURED,
        "confidence": "high",
        "kind": _string(payload.get("kind")),
        "phase": _string(payload.get("phase")),
        "current": current,
        "total": total,
        "unit": _string(payload.get("unit")),
        "percent": percent,
        "message": _string(payload.get("message"), limit=500),
        "updated_at": iso_utc(updated),
        "started_at": iso_utc(started),
        "stale": stale,
        "eta_seconds": eta,
        "completion": completion,
        "error": _string(payload.get("error"), limit=1000),
        "metrics": _sanitize_metrics(payload.get("metrics")),
    }


def _estimate_eta(
    current: Optional[float],
    total: Optional[float],
    started: Optional[datetime],
    updated: Optional[datetime],
    completion: str,
    stale: bool,
) -> Optional[int]:
    """Linear ETA from observed throughput. Returns None whenever that would be dishonest."""
    if completion != "running" or stale:
        return None
    if current is None or total is None or started is None or updated is None:
        return None
    if current <= 0 or total <= current:
        return None
    elapsed = (updated - started).total_seconds()
    if elapsed <= 0:
        return None
    rate = current / elapsed
    if rate <= 0:
        return None
    remaining = (total - current) / rate
    if remaining < 0 or remaining > 365 * 24 * 3600:
        return None
    return int(remaining)


def _number(value: Any) -> Optional[float]:
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number != number or number in (float("inf"), float("-inf")):
        return None
    return number


def _string(value: Any, limit: int = 200) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    return text[:limit]


def _sanitize_metrics(value: Any) -> Dict[str, Any]:
    """Bound the size and types of free-form metrics before they cross the wire."""
    if not isinstance(value, dict):
        return {}
    out: Dict[str, Any] = {}
    for key, raw in value.items():
        if len(out) >= MAX_METRICS:
            break
        name = str(key)[:MAX_METRIC_KEY_CHARS]
        if raw is None or isinstance(raw, bool):
            out[name] = raw
        elif isinstance(raw, (int, float)):
            number = float(raw)
            if number != number:
                out[name] = "nan"
            elif number in (float("inf"), float("-inf")):
                out[name] = "inf" if number > 0 else "-inf"
            else:
                out[name] = raw
        else:
            out[name] = str(raw)[:MAX_METRIC_STRING_CHARS]
    return out
