"""Input validation.

Every value that reaches an ``argv`` element of a Slurm command goes through here first. The
agent never builds a shell string, but strict validation still matters: it keeps malformed ids
from reaching ``scancel``, and it bounds the sizes of anything we echo back.
"""

from __future__ import annotations

import re
from typing import Iterable, List, Optional

from .errors import InvalidArgument

# 123 | 123_4 | 123_[5-9] is deliberately NOT accepted: SlurmBar addresses one concrete task.
# A trailing step suffix (123.batch) is accepted only where a step id is meaningful.
_JOB_ID_RE = re.compile(r"^(?P<job>\d{1,18})(?:_(?P<task>\d{1,18}))?$")
_JOB_STEP_ID_RE = re.compile(r"^\d{1,18}(?:_\d{1,18})?(?:\.(?:batch|extern|\d{1,9}))?$")
_USER_RE = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._@-]{0,63}$")

MAX_JOB_IDS = 512


def validate_job_id(value: str) -> str:
    """Return a canonical job id, or raise :class:`InvalidArgument`.

    Accepts ``123`` and array-task form ``123_4``. Rejects everything else, including ranges,
    whitespace, shell metacharacters and over-long input.
    """
    if not isinstance(value, str):
        raise InvalidArgument("job id must be a string")
    candidate = value.strip()
    if not candidate:
        raise InvalidArgument("job id must not be empty")
    if len(candidate) > 40:
        raise InvalidArgument("job id is too long")
    if not _JOB_ID_RE.match(candidate):
        raise InvalidArgument(
            f"invalid job id {candidate!r}: expected digits, optionally <job>_<task>"
        )
    return candidate


def is_valid_job_id(value: str) -> bool:
    try:
        validate_job_id(value)
        return True
    except InvalidArgument:
        return False


def validate_job_step_id(value: str) -> str:
    """Like :func:`validate_job_id` but also allows ``123.batch`` / ``123.0`` step ids."""
    candidate = (value or "").strip()
    if not candidate or len(candidate) > 48 or not _JOB_STEP_ID_RE.match(candidate):
        raise InvalidArgument(f"invalid job step id {candidate!r}")
    return candidate


def validate_job_ids(values: Iterable[str]) -> List[str]:
    out: List[str] = []
    for value in values:
        out.append(validate_job_id(value))
        if len(out) > MAX_JOB_IDS:
            raise InvalidArgument(f"too many job ids (max {MAX_JOB_IDS})")
    return out


def validate_user(value: Optional[str]) -> Optional[str]:
    """Validate a POSIX-ish user name used as a ``squeue -u`` / ``sacct -u`` argument."""
    if value is None:
        return None
    candidate = value.strip()
    if not candidate:
        return None
    if not _USER_RE.match(candidate):
        raise InvalidArgument(f"invalid user name {candidate!r}")
    return candidate


def validate_stream(value: str) -> str:
    if value not in ("stdout", "stderr"):
        raise InvalidArgument("stream must be 'stdout' or 'stderr'")
    return value


def clamp_int(value: int, low: int, high: int) -> int:
    return max(low, min(high, int(value)))


def base_job_id(job_id: str) -> str:
    """``123_4`` -> ``123``; ``123`` -> ``123``. Input must already be validated."""
    return job_id.split("_", 1)[0]
