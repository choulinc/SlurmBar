"""Constants and small builders for the SlurmBar wire protocol.

The canonical definition lives in ``protocol/schema/*.json`` at the repository root. This module
is the Python-side mirror of it; ``tests/test_protocol_schema.py`` checks that generated payloads
still validate against the schema files.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Optional

SCHEMA_VERSION = 1
AGENT_VERSION = "0.2.4"

# --- normalized job states -------------------------------------------------------------------

STATE_PENDING = "PENDING"
STATE_RUNNING = "RUNNING"
STATE_SUSPENDED = "SUSPENDED"
STATE_COMPLETING = "COMPLETING"
STATE_COMPLETED = "COMPLETED"
STATE_FAILED = "FAILED"
STATE_CANCELLED = "CANCELLED"
STATE_TIMEOUT = "TIMEOUT"
STATE_OUT_OF_MEMORY = "OUT_OF_MEMORY"
STATE_NODE_FAIL = "NODE_FAIL"
STATE_PREEMPTED = "PREEMPTED"
STATE_BOOT_FAIL = "BOOT_FAIL"
STATE_DEADLINE = "DEADLINE"
STATE_REQUEUED = "REQUEUED"
STATE_UNKNOWN = "UNKNOWN"

NORMALIZED_STATES = (
    STATE_PENDING,
    STATE_RUNNING,
    STATE_SUSPENDED,
    STATE_COMPLETING,
    STATE_COMPLETED,
    STATE_FAILED,
    STATE_CANCELLED,
    STATE_TIMEOUT,
    STATE_OUT_OF_MEMORY,
    STATE_NODE_FAIL,
    STATE_PREEMPTED,
    STATE_BOOT_FAIL,
    STATE_DEADLINE,
    STATE_REQUEUED,
    STATE_UNKNOWN,
)

ACTIVE_STATES = frozenset({STATE_PENDING, STATE_RUNNING, STATE_SUSPENDED, STATE_COMPLETING})
FAILURE_STATES = frozenset(
    {
        STATE_FAILED,
        STATE_TIMEOUT,
        STATE_OUT_OF_MEMORY,
        STATE_NODE_FAIL,
        STATE_BOOT_FAIL,
        STATE_DEADLINE,
    }
)

# --- memory semantics ------------------------------------------------------------------------

MEM_PEAK_RSS = "peak_rss"
MEM_PEAK_RSS_PER_STEP = "peak_rss_per_step"
MEM_CURRENT_RSS = "current_rss"
MEM_REQUESTED_TOTAL = "requested_total"
MEM_REQUESTED_PER_NODE = "requested_per_node"
MEM_REQUESTED_PER_CPU = "requested_per_cpu"
MEM_UNAVAILABLE = "unavailable"

# --- progress sources ------------------------------------------------------------------------

PROGRESS_SOURCE_STRUCTURED = "structured_file"
PROGRESS_SOURCE_LOG = "log_parser"

# --- warning codes ---------------------------------------------------------------------------


class W:
    """Stable warning codes. Consumers must tolerate unknown codes."""

    SLURM_MISSING = "SLURM_MISSING"
    SQUEUE_FAILED = "SQUEUE_FAILED"
    SQUEUE_JSON_UNSUPPORTED = "SQUEUE_JSON_UNSUPPORTED"
    SQUEUE_TEXT_UNPARSABLE = "SQUEUE_TEXT_UNPARSABLE"
    SACCT_UNAVAILABLE = "SACCT_UNAVAILABLE"
    SACCT_FAILED = "SACCT_FAILED"
    ACCOUNTING_DISABLED = "ACCOUNTING_DISABLED"
    SSTAT_UNAVAILABLE = "SSTAT_UNAVAILABLE"
    SSTAT_FAILED = "SSTAT_FAILED"
    MEMORY_UNAVAILABLE = "MEMORY_UNAVAILABLE"
    GPU_METRICS_UNAVAILABLE = "GPU_METRICS_UNAVAILABLE"
    PROGRESS_DIR_MISSING = "PROGRESS_DIR_MISSING"
    PROGRESS_FILE_INVALID = "PROGRESS_FILE_INVALID"
    PROGRESS_SCHEMA_UNSUPPORTED = "PROGRESS_SCHEMA_UNSUPPORTED"
    PROGRESS_STALE = "PROGRESS_STALE"
    LOG_PATH_UNKNOWN = "LOG_PATH_UNKNOWN"
    LOG_UNREADABLE = "LOG_UNREADABLE"
    LOG_PROGRESS_BUDGET_EXCEEDED = "LOG_PROGRESS_BUDGET_EXCEEDED"
    COMMAND_TIMEOUT = "COMMAND_TIMEOUT"
    COMMAND_FAILED = "COMMAND_FAILED"
    PARTIAL_DATA = "PARTIAL_DATA"


@dataclass
class Warning_:
    """A structured, nonfatal problem worth showing in the UI."""

    code: str
    message: str
    severity: str = "warning"
    detail: Optional[str] = None
    job_id: Optional[str] = None

    def to_json(self) -> Dict[str, Any]:
        return {
            "code": self.code,
            "message": self.message,
            "severity": self.severity,
            "detail": self.detail,
            "job_id": self.job_id,
        }


@dataclass
class WarningCollector:
    """Accumulates warnings without letting duplicates pile up."""

    items: List[Warning_] = field(default_factory=list)
    _seen: set = field(default_factory=set, repr=False)

    def add(
        self,
        code: str,
        message: str,
        severity: str = "warning",
        detail: Optional[str] = None,
        job_id: Optional[str] = None,
    ) -> None:
        key = (code, message, job_id)
        if key in self._seen:
            return
        self._seen.add(key)
        self.items.append(Warning_(code, message, severity, detail, job_id))

    def extend(self, others: Iterable[Warning_]) -> None:
        for w in others:
            self.add(w.code, w.message, w.severity, w.detail, w.job_id)

    def to_json(self) -> List[Dict[str, Any]]:
        return [w.to_json() for w in self.items]

    def __len__(self) -> int:  # pragma: no cover - trivial
        return len(self.items)


def empty_resources() -> Dict[str, Any]:
    """Resource block with everything honestly marked unavailable."""
    return {
        "memory_used_bytes": None,
        "memory_limit_bytes": None,
        "memory_semantics": MEM_UNAVAILABLE,
        "memory_limit_semantics": MEM_UNAVAILABLE,
        "gpu_memory_used_bytes": None,
        "gpu_memory_limit_bytes": None,
        "gpu_utilization_percent": None,
        "cpu_utilization_percent": None,
    }
