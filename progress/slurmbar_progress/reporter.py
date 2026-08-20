"""``ProgressReporter`` — the workload side of SlurmBar's structured progress.

Slurm knows a job is RUNNING. It does not know the job is on epoch 375 of 1000 with a loss of
0.059. This module is how the job says so.

Design constraints, in priority order:

1. **Never break the workload.** Every public method swallows its own errors. A full disk or a
   hung mount degrades SlurmBar's display; it does not kill a 40-hour training run.
2. **Never hammer the filesystem.** Updates are rate limited (default: at most one write every
   5 s), because a per-batch call on a shared parallel filesystem is a real metadata problem.
3. **Never lose the last state.** Phase changes, completion and failure always force a write.
"""

from __future__ import annotations

import os
import socket
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, Mapping, Optional

from ._atomic import atomic_write_json

SCHEMA_VERSION = 1
WRITER = "slurmbar_progress/0.2.6"

DEFAULT_MIN_INTERVAL_SECONDS = 5.0
STATUS_FILENAME = "status.json"

COMPLETION_RUNNING = "running"
COMPLETION_COMPLETED = "completed"
COMPLETION_FAILED = "failed"

MAX_METRICS = 64
MAX_STRING_CHARS = 500


def default_state_dir() -> str:
    """``$SLURMBAR_STATE_DIR``, else ``$XDG_STATE_HOME/slurmbar/jobs``, else the documented default."""
    override = os.environ.get("SLURMBAR_STATE_DIR")
    if override:
        return os.path.expanduser(override)
    xdg = os.environ.get("XDG_STATE_HOME")
    if xdg:
        return os.path.join(os.path.expanduser(xdg), "slurmbar", "jobs")
    return os.path.expanduser("~/.local/state/slurmbar/jobs")


def detect_job_id() -> str:
    """Best available job identity.

    Inside an array task Slurm sets both ``SLURM_ARRAY_JOB_ID`` and ``SLURM_ARRAY_TASK_ID``; the
    id the queue displays is ``<array_job>_<task>``, and that is what SlurmBar matches on.
    Outside Slurm the reporter still works, using a local id so scripts can be tested on a
    laptop.
    """
    array_job = os.environ.get("SLURM_ARRAY_JOB_ID")
    array_task = os.environ.get("SLURM_ARRAY_TASK_ID")
    if array_job and array_task:
        return f"{array_job}_{array_task}"
    job_id = os.environ.get("SLURM_JOB_ID") or os.environ.get("SLURM_JOBID")
    if job_id:
        return job_id
    return f"local-{os.getpid()}"


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def _clip(value: Any, limit: int = MAX_STRING_CHARS) -> Optional[str]:
    if value is None:
        return None
    text = str(value)
    return text[:limit] if text else None


class ProgressReporter:
    """Writes ``<state_dir>/<job_id>/status.json`` for SlurmBar to read.

    Example::

        reporter = ProgressReporter(kind="training")
        for epoch in range(total_epochs):
            loss = train_one_epoch()
            reporter.update(current=epoch + 1, total=total_epochs, unit="epoch",
                            phase="train", metrics={"loss": float(loss)})
        reporter.complete(message="Training finished")
    """

    def __init__(
        self,
        kind: str = "generic",
        job_id: Optional[str] = None,
        state_dir: Optional[str] = None,
        min_interval_seconds: float = DEFAULT_MIN_INTERVAL_SECONDS,
        unit: Optional[str] = None,
        total: Optional[float] = None,
        phase: Optional[str] = None,
        fsync: bool = True,
        verbose: bool = False,
        write_on_init: bool = True,
    ) -> None:
        self.kind = kind
        self.job_id = job_id or detect_job_id()
        self.state_dir = os.path.expanduser(state_dir or default_state_dir())
        self.min_interval_seconds = max(0.0, float(min_interval_seconds))
        self.fsync = fsync
        self.verbose = verbose

        self.job_dir = os.path.join(self.state_dir, self.job_id)
        self.path = os.path.join(self.job_dir, STATUS_FILENAME)

        self._started_at = _now_iso()
        self._last_write_monotonic: Optional[float] = None
        self._disabled = False
        self._error_count = 0

        self._state: Dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "job_id": self.job_id,
            "array_job_id": os.environ.get("SLURM_ARRAY_JOB_ID"),
            "array_task_id": os.environ.get("SLURM_ARRAY_TASK_ID"),
            "pid": os.getpid(),
            "hostname": _hostname(),
            "kind": kind,
            "phase": phase,
            "current": None,
            "total": total,
            "unit": unit,
            "message": None,
            "metrics": {},
            "started_at": self._started_at,
            "updated_at": self._started_at,
            "completion": COMPLETION_RUNNING,
            "error": None,
            "writer": WRITER,
        }

        if write_on_init:
            # Construction must never raise into the workload either: a bad state directory is
            # discovered here, and it degrades to "no progress reporting", not a crashed job.
            self._guarded_write(force=True)

    # -- public API ------------------------------------------------------------------------

    def update(
        self,
        current: Optional[float] = None,
        total: Optional[float] = None,
        unit: Optional[str] = None,
        phase: Optional[str] = None,
        message: Optional[str] = None,
        metrics: Optional[Mapping[str, Any]] = None,
        force: bool = False,
    ) -> bool:
        """Record progress. Returns True when a file write actually happened.

        Safe to call every batch: the rate limiter drops writes that are too close together,
        keeping the in-memory state current so the next write is not stale. A change of
        ``phase`` always forces a write so the end of a phase is never lost.
        """
        if self._disabled:
            return False
        try:
            if phase is not None and phase != self._state.get("phase"):
                force = True
            if current is not None:
                self._state["current"] = _number(current)
            if total is not None:
                self._state["total"] = _number(total)
            if unit is not None:
                self._state["unit"] = _clip(unit, 64)
            if phase is not None:
                self._state["phase"] = _clip(phase, 64)
            if message is not None:
                self._state["message"] = _clip(message)
            if metrics:
                merged = dict(self._state.get("metrics") or {})
                merged.update(_sanitize_metrics(metrics))
                self._state["metrics"] = dict(list(merged.items())[:MAX_METRICS])
            return self._write(force=force)
        except Exception as exc:  # never propagate into the workload
            self._note_error(exc)
            return False

    def set_total(self, total: Optional[float], force: bool = False) -> bool:
        return self.update(total=total, force=force)

    def message(self, text: str, force: bool = True) -> bool:
        """Post a human-readable status line. Forced by default — messages are events."""
        return self.update(message=text, force=force)

    def advance(self, amount: float = 1.0, **kwargs: Any) -> bool:
        """Increment ``current`` by ``amount``. Convenient for generic item counters."""
        if self._disabled:
            return False
        current = self._state.get("current") or 0.0
        return self.update(current=current + amount, **kwargs)

    def complete(self, message: Optional[str] = None, current: Optional[float] = None) -> bool:
        """Mark the workload finished successfully. Always written."""
        if self._disabled:
            return False
        try:
            if current is not None:
                self._state["current"] = _number(current)
            elif self._state.get("total") is not None:
                self._state["current"] = self._state["total"]
            self._state["completion"] = COMPLETION_COMPLETED
            self._state["error"] = None
            if message is not None:
                self._state["message"] = _clip(message)
            return self._write(force=True)
        except Exception as exc:
            self._note_error(exc)
            return False

    def fail(self, error: Optional[str] = None, message: Optional[str] = None) -> bool:
        """Mark the workload failed, with an optional short error summary. Always written."""
        if self._disabled:
            return False
        try:
            self._state["completion"] = COMPLETION_FAILED
            self._state["error"] = _clip(error, 1000)
            if message is not None:
                self._state["message"] = _clip(message)
            return self._write(force=True)
        except Exception as exc:
            self._note_error(exc)
            return False

    def flush(self) -> bool:
        """Force the current in-memory state to disk, bypassing the rate limiter."""
        if self._disabled:
            return False
        try:
            return self._write(force=True)
        except Exception as exc:
            self._note_error(exc)
            return False

    @property
    def status_path(self) -> str:
        return self.path

    def snapshot(self) -> Dict[str, Any]:
        """A copy of the current in-memory state. Useful in tests and for logging."""
        state = dict(self._state)
        state["metrics"] = dict(state.get("metrics") or {})
        return state

    # -- context manager -------------------------------------------------------------------

    def __enter__(self) -> "ProgressReporter":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        if exc_type is None:
            self.complete()
        elif exc_type is KeyboardInterrupt:
            self.fail(error="Interrupted")
        else:
            self.fail(error=f"{exc_type.__name__}: {exc}")
        return False  # never swallow the workload's exception

    # -- internals -------------------------------------------------------------------------

    def _should_write(self, force: bool) -> bool:
        if force or self.min_interval_seconds <= 0:
            return True
        if self._last_write_monotonic is None:
            return True
        return (time.monotonic() - self._last_write_monotonic) >= self.min_interval_seconds

    def _write(self, force: bool) -> bool:
        if not self._should_write(force):
            return False
        self._state["updated_at"] = _now_iso()
        atomic_write_json(self.path, self._state, fsync=self.fsync)
        self._last_write_monotonic = time.monotonic()
        return True

    def _guarded_write(self, force: bool) -> bool:
        try:
            return self._write(force=force)
        except Exception as exc:
            self._note_error(exc)
            return False

    def _note_error(self, exc: BaseException) -> None:
        self._error_count += 1
        if self.verbose or self._error_count == 1:
            print(
                f"[slurmbar_progress] progress reporting failed ({type(exc).__name__}: {exc}); "
                "the workload is unaffected.",
                file=sys.stderr,
            )
        if self._error_count >= 10:
            self._disabled = True
            print(
                "[slurmbar_progress] disabling progress reporting after repeated failures.",
                file=sys.stderr,
            )


def _hostname() -> Optional[str]:
    try:
        return socket.gethostname()
    except OSError:  # pragma: no cover
        return None


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


def _sanitize_metrics(metrics: Mapping[str, Any]) -> Dict[str, Any]:
    """Keep metrics JSON-safe. NaN and inf become strings so they survive the wire honestly."""
    out: Dict[str, Any] = {}
    for key, value in list(metrics.items())[:MAX_METRICS]:
        name = str(key)[:64]
        if value is None or isinstance(value, bool):
            out[name] = value
        elif isinstance(value, (int, float)):
            number = float(value)
            if number != number:
                out[name] = "nan"
            elif number in (float("inf"), float("-inf")):
                out[name] = "inf" if number > 0 else "-inf"
            else:
                out[name] = value
        else:
            out[name] = str(value)[:200]
    return out
