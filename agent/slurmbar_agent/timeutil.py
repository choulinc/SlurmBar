"""Slurm value parsing: timestamps, durations and memory sizes.

Slurm prints timezone-naive local timestamps. The agent runs on the login node, so it is the
only place in the system that can convert them correctly — the Mac may well be in a different
timezone. Everything leaves this module as UTC.
"""

from __future__ import annotations

import math
import re
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

# Values Slurm uses to mean "nothing here".
_EMPTY = {
    "",
    "n/a",
    "none",
    "unknown",
    "(null)",
    "null",
    "unlimited",
    "invalid",
    "not_set",
    "no_val",
    "nan",
}

_ISO_FORMATS = (
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%dT%H:%M",
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S.%f",
)

# Slurm sentinel for "no value" in unix-epoch fields.
_EPOCH_SENTINELS = {0, -1, 0xFFFFFFFE, 0x7FFFFFFF, 4294967294}


def is_empty(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, str):
        return value.strip().lower() in _EMPTY
    return False


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_utc(moment: Optional[datetime]) -> Optional[str]:
    """Format as ``2026-07-22T02:30:00Z``. Naive input is assumed to be local login-node time."""
    if moment is None:
        return None
    if moment.tzinfo is None:
        moment = moment.astimezone()
    return moment.astimezone(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_slurm_time(value: Any) -> Optional[datetime]:
    """Parse a Slurm timestamp into an aware UTC datetime, or None.

    Handles the three shapes Slurm actually emits:

    * ``"2026-07-22T00:10:00"`` (text output; local login-node time),
    * ``1753142400`` (``--json`` in Slurm < 23.11),
    * ``{"set": true, "infinite": false, "number": 1753142400}`` (``--json`` in Slurm >= 23.11).
    """
    if isinstance(value, dict):
        if not value.get("set", True) or value.get("infinite"):
            return None
        value = value.get("number")

    if is_empty(value):
        return None

    if isinstance(value, bool):
        return None

    if isinstance(value, (int, float)):
        seconds = int(value)
        if seconds in _EPOCH_SENTINELS or seconds <= 0:
            return None
        try:
            return datetime.fromtimestamp(seconds, tz=timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None

    if not isinstance(value, str):
        return None

    text = value.strip()
    if text.isdigit() or (text.startswith("-") and text[1:].isdigit()):
        return parse_slurm_time(int(text))

    # Two dialects arrive here: Slurm's naive local time ("2026-07-22T00:10:00") and the
    # progress SDK's explicit UTC ("2026-07-22T02:29:55Z"). fromisoformat covers both; the
    # tzinfo it produces is what distinguishes them.
    candidate = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
    try:
        parsed: Optional[datetime] = datetime.fromisoformat(candidate)
    except ValueError:
        parsed = None
    if parsed is None:
        for fmt in _ISO_FORMATS:
            try:
                parsed = datetime.strptime(text, fmt)
                break
            except ValueError:
                continue
    if parsed is None:
        return None
    if parsed.tzinfo is None:
        # Naive values are login-node local time; astimezone() attaches the local zone.
        return parsed.astimezone().astimezone(timezone.utc)
    return parsed.astimezone(timezone.utc)


def parse_slurm_time_iso(value: Any) -> Optional[str]:
    return iso_utc(parse_slurm_time(value))


_DURATION_RE = re.compile(
    r"^(?:(?P<days>\d+)-)?(?:(?P<hours>\d+):)?(?P<minutes>\d+):(?P<seconds>\d+)(?:\.\d+)?$"
)


def parse_duration_seconds(value: Any) -> Optional[int]:
    """Parse Slurm elapsed/limit strings into integer seconds.

    Accepts ``DD-HH:MM:SS``, ``HH:MM:SS``, ``MM:SS``, ``DD-HH``, plain integers and the
    ``{"set","infinite","number"}`` wrapper. ``UNLIMITED``/``INVALID`` become ``None`` — an
    unlimited time limit is genuinely "no limit", not zero.
    """
    if isinstance(value, dict):
        if not value.get("set", True) or value.get("infinite"):
            return None
        value = value.get("number")

    if is_empty(value):
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        seconds = int(value)
        return seconds if seconds >= 0 else None

    text = str(value).strip()
    if text.isdigit():
        return int(text)

    match = _DURATION_RE.match(text)
    if match:
        days = int(match.group("days") or 0)
        hours = int(match.group("hours") or 0)
        minutes = int(match.group("minutes"))
        seconds = int(match.group("seconds"))
        return days * 86400 + hours * 3600 + minutes * 60 + seconds

    # "5-12" means 5 days 12 hours.
    day_hour = re.match(r"^(\d+)-(\d+)$", text)
    if day_hour:
        return int(day_hour.group(1)) * 86400 + int(day_hour.group(2)) * 3600
    return None


def parse_minutes_to_seconds(value: Any) -> Optional[int]:
    """``squeue --json`` reports ``time_limit`` in minutes."""
    if isinstance(value, dict):
        if not value.get("set", True) or value.get("infinite"):
            return None
        value = value.get("number")
    if is_empty(value) or isinstance(value, bool):
        return None
    try:
        minutes = int(value)
    except (TypeError, ValueError):
        return parse_duration_seconds(value)
    if minutes <= 0:
        return None
    return minutes * 60


_SIZE_RE = re.compile(
    r"^(?P<number>\d+(?:\.\d+)?)\s*(?P<unit>[KMGTPE])?(?:[Ii]?[Bb])?(?P<per>[NnCc])?$"
)

_UNIT_FACTORS = {
    "": 1,
    "K": 1024,
    "M": 1024**2,
    "G": 1024**3,
    "T": 1024**4,
    "P": 1024**5,
    "E": 1024**6,
}


class MemoryValue:
    """A parsed Slurm memory value plus the per-node/per-cpu suffix Slurm sometimes attaches."""

    __slots__ = ("bytes", "per")

    def __init__(self, num_bytes: Optional[int], per: Optional[str]) -> None:
        self.bytes = num_bytes
        self.per = per  # "n" per node, "c" per cpu, or None

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"MemoryValue(bytes={self.bytes}, per={self.per!r})"

    def __eq__(self, other: object) -> bool:
        return (
            isinstance(other, MemoryValue) and other.bytes == self.bytes and other.per == self.per
        )


def parse_memory(value: Any, default_unit: str = "M") -> MemoryValue:
    """Parse ``16G``, ``4000Mc``, ``123456K``, ``1.5G``, ``0`` into bytes.

    ``default_unit`` applies to bare numbers. Slurm's text output for ``ReqMem`` and
    ``MinMemory`` is megabytes when unsuffixed; ``sstat``/``sacct`` ``MaxRSS`` is kilobytes.
    """
    if isinstance(value, dict):
        if not value.get("set", True) or value.get("infinite"):
            return MemoryValue(None, None)
        value = value.get("number")

    if is_empty(value):
        return MemoryValue(None, None)
    if isinstance(value, bool):
        return MemoryValue(None, None)
    if isinstance(value, (int, float)):
        if value < 0:
            return MemoryValue(None, None)
        return MemoryValue(int(float(value) * _UNIT_FACTORS[default_unit]), None)

    text = str(value).strip()
    if not text:
        return MemoryValue(None, None)

    match = _SIZE_RE.match(text.replace(" ", ""))
    if not match:
        return MemoryValue(None, None)

    number = float(match.group("number"))
    unit = (match.group("unit") or default_unit).upper()
    per = match.group("per")
    per = per.lower() if per else None
    try:
        num_bytes = int(number * _UNIT_FACTORS[unit])
    except (KeyError, OverflowError, ValueError):
        return MemoryValue(None, None)
    return MemoryValue(num_bytes, per)


def parse_exit_code(value: Any) -> tuple[Optional[int], Optional[int]]:
    """Parse ``0:0`` / ``1:0`` / ``{"return_code": …}`` into ``(exit_code, signal)``."""
    if isinstance(value, dict):
        # Slurm >= 23.11: {"status": ["SUCCESS"], "return_code": {"set":true,"number":0}, ...}
        rc = value.get("return_code")
        if isinstance(rc, dict):
            rc = rc.get("number") if rc.get("set", True) else None
        sig = value.get("signal")
        if isinstance(sig, dict):
            sig_id = sig.get("id")
            if isinstance(sig_id, dict):
                # Slurm 25.11 nests the id in its own wrapper. `set: false` means "no signal",
                # which is not the same as "signal 0" and must not be reported as one.
                sig = sig_id.get("number") if sig_id.get("set", True) else None
            else:
                sig = sig_id
        try:
            return (int(rc) if rc is not None else None, int(sig) if sig is not None else None)
        except (TypeError, ValueError):
            return (None, None)

    if is_empty(value):
        return (None, None)
    if isinstance(value, int):
        return (value, None)

    text = str(value).strip()
    if ":" in text:
        left, _, right = text.partition(":")
        try:
            return (int(left), int(right) if right.strip().isdigit() else None)
        except ValueError:
            return (None, None)
    try:
        return (int(text), None)
    except ValueError:
        return (None, None)


def elapsed_between(start: Optional[datetime], end: Optional[datetime]) -> Optional[int]:
    if start is None:
        return None
    finish = end or utc_now()
    delta = finish - start
    seconds = int(delta.total_seconds())
    return max(0, seconds)


def seconds_since(moment: Optional[datetime], now: Optional[datetime] = None) -> Optional[float]:
    if moment is None:
        return None
    return ((now or utc_now()) - moment).total_seconds()


def clamp_percent(value: Optional[float]) -> Optional[float]:
    if value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if math.isnan(number) or math.isinf(number):
        return None
    return max(0.0, min(100.0, round(number, 4)))


def add_seconds(moment: datetime, seconds: float) -> datetime:
    return moment + timedelta(seconds=seconds)
