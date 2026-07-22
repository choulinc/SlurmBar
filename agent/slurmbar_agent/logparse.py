"""Conservative progress inference from the tail of a job log.

This is a *fallback*. Structured progress from ``slurmbar_progress`` always wins. Everything
produced here is labelled ``source="log_parser"`` with a ``confidence`` below ``high``, and the
UI is expected to present it as a guess.

Design rules that keep this from becoming a liability:

* patterns are registered, not hardcoded into one function, so a framework-specific parser can
  be added later without touching the protocol;
* the most specific labelled pattern wins; a bare ``375/1000`` is accepted only as a last
  resort and is marked ``low`` confidence;
* the parser scans a bounded list of tail lines, newest first, and stops at the first match;
* nothing is ever extrapolated — no ETA is invented from log text alone.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

CONF_HIGH = "high"
CONF_MEDIUM = "medium"
CONF_LOW = "low"

#: How many tail lines to inspect. Bounded so a huge tqdm log cannot dominate a refresh.
MAX_SCAN_LINES = 400


@dataclass(frozen=True)
class ProgressPattern:
    """A named counter pattern: ``current`` / ``total`` plus the unit it counts in."""

    name: str
    unit: str
    regex: re.Pattern
    confidence: str
    priority: int  # higher wins


def _p(name: str, unit: str, pattern: str, confidence: str, priority: int) -> ProgressPattern:
    return ProgressPattern(name, unit, re.compile(pattern, re.IGNORECASE), confidence, priority)


#: Ordered by specificity. `Epoch 12/100` is far more trustworthy than a bare `12/100`.
COUNTER_PATTERNS: Tuple[ProgressPattern, ...] = (
    _p("epoch", "epoch", r"\bepochs?\b[\s:=\[]*(\d+)\s*/\s*(\d+)", CONF_MEDIUM, 100),
    _p("epoch_of", "epoch", r"\bepochs?\b[\s:=]*(\d+)\s+of\s+(\d+)", CONF_MEDIUM, 95),
    _p("timestep", "timestep", r"\b(?:timestep|time step|tstep)\b[\s:=\[]*(\d+)\s*/\s*(\d+)", CONF_MEDIUM, 90),
    _p("step", "step", r"\b(?:global[_ ]?step|step|iter|iteration)\b[\s:=\[]*(\d+)\s*/\s*(\d+)", CONF_MEDIUM, 85),
    _p("sample", "item", r"\b(?:sample|file|item|record|chunk|shard|trial)s?\b[\s:=\[]*(\d+)\s*/\s*(\d+)", CONF_MEDIUM, 80),
    _p("batch", "batch", r"\bbatch(?:es)?\b[\s:=\[]*(\d+)\s*/\s*(\d+)", CONF_MEDIUM, 70),
    # Bare "375/1000" appearing on its own. Genuinely ambiguous, so: low confidence.
    _p("bare", "step", r"(?:^|[\s\[(])(\d{1,9})\s*/\s*(\d{1,9})(?:$|[\s\]),])", CONF_LOW, 10),
)

#: tqdm renders `  38%|███       | 375/1000 [01:12<02:03, ...]`.
_TQDM_RE = re.compile(r"(\d{1,3})%\s*\|")

_NUMBER = r"([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?|nan|inf|-inf)"

_METRIC_PATTERNS: Dict[str, re.Pattern] = {
    # `avg_loss` has no word boundary before "loss", so a \bloss\b pattern never sees it.
    # Frameworks commonly report an epoch-level average alongside a per-batch value.
    "avg_loss": re.compile(r"\b(?:avg|mean|epoch|running)[_ ]?loss\b\s*[=:]\s*" + _NUMBER, re.IGNORECASE),
    "loss": re.compile(r"\b(?:train[_ ]?)?loss\b\s*[=:]\s*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?|nan|inf|-inf)", re.IGNORECASE),
    "val_loss": re.compile(r"\b(?:val|valid|validation)[_ ]?loss\b\s*[=:]\s*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?|nan|inf)", re.IGNORECASE),
    "learning_rate": re.compile(r"\b(?:lr|learning[_ ]?rate)\b\s*[=:]\s*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)", re.IGNORECASE),
    "accuracy": re.compile(r"\b(?:acc|accuracy)\b\s*[=:]\s*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)", re.IGNORECASE),
}

_BATCH_RE = re.compile(r"\bbatch(?:es)?\b[\s:=\[]*(\d+)\s*/\s*(\d+)", re.IGNORECASE)

#: Sub-epoch position written as `Epoch 35 [27/94]` — a common convention that never uses the
#: word "batch". Anchored to `<word> <number> [` so that bracketed dates and bare `[a/b]`
#: fragments elsewhere in a line are not mistaken for a counter.
_BRACKET_BATCH_RE = re.compile(r"\b\w+\s+\d+\s*\[\s*(\d+)\s*/\s*(\d+)\s*\]")

#: Extra parsers can be appended here without changing the JSON protocol.
CustomParser = Callable[[Sequence[str]], Optional[Dict[str, Any]]]
CUSTOM_PARSERS: List[CustomParser] = []


@dataclass
class ParsedProgress:
    current: Optional[float] = None
    total: Optional[float] = None
    unit: Optional[str] = None
    percent: Optional[float] = None
    confidence: str = CONF_LOW
    metrics: Dict[str, Any] = None  # type: ignore[assignment]
    pattern: Optional[str] = None

    def __post_init__(self) -> None:
        if self.metrics is None:
            self.metrics = {}

    def to_progress_json(self, updated_at: Optional[str]) -> Dict[str, Any]:
        return {
            "source": "log_parser",
            "confidence": self.confidence,
            "kind": None,
            "phase": None,
            "current": self.current,
            "total": self.total,
            "unit": self.unit,
            "percent": self.percent,
            "message": None,
            "updated_at": updated_at,
            "started_at": None,
            "stale": False,
            "eta_seconds": None,
            "completion": None,
            "error": None,
            "metrics": self.metrics,
        }


def parse_log_lines(lines: Sequence[str]) -> Optional[ParsedProgress]:
    """Infer progress from tail lines (oldest first). Returns None when nothing is confident.

    The newest usable signal wins, but a labelled counter anywhere in the scan window beats a
    bare ratio on the very last line.
    """
    if not lines:
        return None

    window = [line for line in lines[-MAX_SCAN_LINES:] if line.strip()]
    if not window:
        return None

    for parser in CUSTOM_PARSERS:
        try:
            custom = parser(window)
        except Exception:
            custom = None
        if custom:
            return ParsedProgress(**custom)

    best: Optional[ParsedProgress] = None
    best_priority = -1

    for line in reversed(window):
        for pattern in COUNTER_PATTERNS:
            if pattern.priority <= best_priority:
                continue
            match = pattern.regex.search(line)
            if not match:
                continue
            current, total = _to_numbers(match.group(1), match.group(2))
            if current is None or total is None or total <= 0 or current > total * 1.5:
                continue
            best = ParsedProgress(
                current=current,
                total=total,
                unit=pattern.unit,
                percent=_percent(current, total),
                confidence=pattern.confidence,
                pattern=pattern.name,
            )
            best_priority = pattern.priority
        if best_priority >= 100:
            break  # nothing outranks an explicit epoch counter

    if best is None:
        best = _parse_tqdm(window)

    if best is None:
        return None

    best.metrics = _parse_metrics(window)
    return best


def _parse_tqdm(lines: Sequence[str]) -> Optional[ParsedProgress]:
    for line in reversed(lines):
        match = _TQDM_RE.search(line)
        if not match:
            continue
        try:
            percent = float(match.group(1))
        except ValueError:
            continue
        if not 0.0 <= percent <= 100.0:
            continue
        return ParsedProgress(
            current=None,
            total=None,
            unit=None,
            percent=percent,
            confidence=CONF_MEDIUM,
            pattern="tqdm",
        )
    return None


def _parse_metrics(lines: Sequence[str]) -> Dict[str, Any]:
    """Collect the newest occurrence of each known metric."""
    metrics: Dict[str, Any] = {}
    for line in reversed(lines):
        for name, regex in _METRIC_PATTERNS.items():
            if name in metrics:
                continue
            match = regex.search(line)
            if not match:
                continue
            value = _to_float(match.group(1))
            if value is not None:
                metrics[name] = value
        if "batch_current" not in metrics:
            batch = _BATCH_RE.search(line) or _BRACKET_BATCH_RE.search(line)
            if batch:
                current, total = _to_numbers(batch.group(1), batch.group(2))
                if current is not None and total is not None and 0 < total and current <= total:
                    metrics["batch_current"] = current
                    metrics["batch_total"] = total
        if len(metrics) >= len(_METRIC_PATTERNS) + 2:
            break  # every known metric plus batch_current/batch_total
    return metrics


def _to_numbers(left: str, right: str) -> Tuple[Optional[float], Optional[float]]:
    return _to_finite(left), _to_finite(right)


def _to_finite(text: str) -> Optional[float]:
    """Strict numeric conversion for counters: NaN and infinities are rejected outright."""
    try:
        value = float(text)
    except (TypeError, ValueError):
        return None
    if math.isnan(value) or math.isinf(value):
        return None
    return value


def _to_float(text: str) -> Optional[Any]:
    """Metric conversion. NaN/inf are preserved as strings because JSON cannot carry them.

    A NaN loss is one of the most important things a training log can say, so it is reported
    rather than dropped. The app knows to treat the string ``"nan"`` as a NaN metric.
    """
    try:
        value = float(text)
    except (TypeError, ValueError):
        return None
    if math.isnan(value):
        return "nan"
    if math.isinf(value):
        return "inf" if value > 0 else "-inf"
    return value


def _percent(current: float, total: float) -> Optional[float]:
    if not total:
        return None
    return round(max(0.0, min(100.0, current / total * 100.0)), 4)
