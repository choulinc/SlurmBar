"""Slurm state -> normalized state mapping.

Slurm reports states in several shapes depending on version and command:

* long names from ``squeue -o %T`` and ``sacct``: ``RUNNING``, ``OUT_OF_MEMORY``;
* short codes from ``squeue -o %t``: ``R``, ``PD``, ``CG``;
* decorated forms from ``sacct``: ``CANCELLED by 100123``;
* a *list* of flags from ``squeue --json`` in Slurm >= 23.11: ``["RUNNING"]``,
  ``["CANCELLED", "REQUEUED"]``.

The raw string is always preserved separately so the UI can show exactly what Slurm said.
"""

from __future__ import annotations

from typing import Any, Optional, Sequence, Tuple

from .protocol import (
    STATE_BOOT_FAIL,
    STATE_CANCELLED,
    STATE_COMPLETED,
    STATE_COMPLETING,
    STATE_DEADLINE,
    STATE_FAILED,
    STATE_NODE_FAIL,
    STATE_OUT_OF_MEMORY,
    STATE_PENDING,
    STATE_PREEMPTED,
    STATE_REQUEUED,
    STATE_RUNNING,
    STATE_SUSPENDED,
    STATE_TIMEOUT,
    STATE_UNKNOWN,
)

_LONG = {
    "PENDING": STATE_PENDING,
    "RUNNING": STATE_RUNNING,
    "SUSPENDED": STATE_SUSPENDED,
    "COMPLETING": STATE_COMPLETING,
    "COMPLETED": STATE_COMPLETED,
    "CONFIGURING": STATE_PENDING,
    "RESIZING": STATE_RUNNING,
    "SIGNALING": STATE_RUNNING,
    "STAGE_OUT": STATE_COMPLETING,
    "STOPPED": STATE_SUSPENDED,
    "FAILED": STATE_FAILED,
    "CANCELLED": STATE_CANCELLED,
    "TIMEOUT": STATE_TIMEOUT,
    "OUT_OF_MEMORY": STATE_OUT_OF_MEMORY,
    "OUT_OF_ME+": STATE_OUT_OF_MEMORY,  # squeue truncates long state names
    "OUT_OF_MEMORY+": STATE_OUT_OF_MEMORY,
    "NODE_FAIL": STATE_NODE_FAIL,
    "BOOT_FAIL": STATE_BOOT_FAIL,
    "DEADLINE": STATE_DEADLINE,
    "PREEMPTED": STATE_PREEMPTED,
    "REQUEUED": STATE_REQUEUED,
    "REQUEUE_FED": STATE_REQUEUED,
    "REQUEUE_HOLD": STATE_REQUEUED,
    "REVOKED": STATE_CANCELLED,
    "SPECIAL_EXIT": STATE_FAILED,
}

_SHORT = {
    "PD": STATE_PENDING,
    "R": STATE_RUNNING,
    "S": STATE_SUSPENDED,
    "ST": STATE_SUSPENDED,
    "CG": STATE_COMPLETING,
    "CD": STATE_COMPLETED,
    "F": STATE_FAILED,
    "CA": STATE_CANCELLED,
    "TO": STATE_TIMEOUT,
    "OOM": STATE_OUT_OF_MEMORY,
    "NF": STATE_NODE_FAIL,
    "BF": STATE_BOOT_FAIL,
    "DL": STATE_DEADLINE,
    "PR": STATE_PREEMPTED,
    "RQ": STATE_REQUEUED,
    "RD": STATE_PENDING,
    "RF": STATE_REQUEUED,
    "RH": STATE_REQUEUED,
    "RS": STATE_RUNNING,
    "RV": STATE_CANCELLED,
    "SE": STATE_FAILED,
    "SI": STATE_RUNNING,
    "SO": STATE_COMPLETING,
    "CF": STATE_PENDING,
}

# When squeue --json reports several flags at once, the first match here wins. Terminal
# failure reasons outrank the generic lifecycle flags they accompany.
_FLAG_PRIORITY = (
    STATE_OUT_OF_MEMORY,
    STATE_NODE_FAIL,
    STATE_BOOT_FAIL,
    STATE_DEADLINE,
    STATE_TIMEOUT,
    STATE_PREEMPTED,
    STATE_FAILED,
    STATE_CANCELLED,
    STATE_COMPLETING,
    STATE_RUNNING,
    STATE_SUSPENDED,
    STATE_PENDING,
    STATE_REQUEUED,
    STATE_COMPLETED,
)


def normalize_state(value: Any) -> Tuple[str, Optional[str]]:
    """Return ``(normalized_state, raw_state_string)``.

    Never raises and never guesses: anything unrecognized maps to ``UNKNOWN`` with the raw
    text preserved, so a future Slurm state shows up honestly instead of being misfiled.
    """
    if value is None:
        return STATE_UNKNOWN, None

    if isinstance(value, (list, tuple)):
        flags: Sequence[str] = [str(item) for item in value if item is not None]
        raw = "+".join(flags) if flags else None
        mapped = {_map_token(flag) for flag in flags}
        mapped.discard(STATE_UNKNOWN)
        for candidate in _FLAG_PRIORITY:
            if candidate in mapped:
                return candidate, raw
        return STATE_UNKNOWN, raw

    raw = str(value).strip()
    if not raw:
        return STATE_UNKNOWN, None
    return _map_token(raw), raw


def _map_token(token: str) -> str:
    text = str(token).strip().upper()
    if not text:
        return STATE_UNKNOWN
    # "CANCELLED by 100123" / "CANCELLED+"
    head = text.split(" ", 1)[0].rstrip("+")
    for candidate in (text, head):
        if candidate in _LONG:
            return _LONG[candidate]
    if head in _SHORT:
        return _SHORT[head]
    # Some Slurm builds emit "JOB_STATE_RUNNING" style identifiers.
    if head.startswith("JOB_STATE_") and head[len("JOB_STATE_") :] in _LONG:
        return _LONG[head[len("JOB_STATE_") :]]
    return STATE_UNKNOWN


def is_terminal(state: str) -> bool:
    return state not in (STATE_PENDING, STATE_RUNNING, STATE_SUSPENDED, STATE_COMPLETING)
