"""``scontrol show job`` — used only on demand, never during a routine snapshot.

``squeue -o`` cannot report ``StdOut``/``StdErr``, so when the text fallback is in play the log
paths are resolved here, for one job, at the moment the user asks to see its logs. That keeps
the per-refresh controller load at one RPC while still making logs work everywhere.
"""

from __future__ import annotations

import re
from typing import Any, Dict, Optional

from .runner import CommandRunner
from .timeutil import is_empty

# scontrol emits `Key=Value` pairs where a value may contain spaces (Command=/bin/sh -c ...).
# Anchor each value to the next `Key=` token rather than splitting naively on whitespace.
_KV_RE = re.compile(r"(?P<key>[A-Za-z_][A-Za-z0-9_/:]*)=(?P<value>.*?)(?=\s+[A-Za-z_][A-Za-z0-9_/:]*=|$)")

_FILENAME_PATTERN_RE = re.compile(r"%(%|\d*[AaJjNnstuxX])")


def show_job(runner: CommandRunner, job_id: str, timeout: float = 10.0) -> Optional[Dict[str, str]]:
    """Return the flattened key/value map for one job, or None when it is unavailable.

    ``job_id`` must already be validated by :mod:`slurmbar_agent.validate`.
    """
    if runner.which("scontrol") is None:
        return None
    result = runner.run(["scontrol", "--oneliner", "show", "job", job_id], timeout=timeout)
    if not result.ok or not result.stdout.strip():
        return None
    return parse_scontrol(result.stdout)


def parse_scontrol(payload: str) -> Dict[str, str]:
    fields: Dict[str, str] = {}
    for line in payload.splitlines():
        if not line.strip():
            continue
        for match in _KV_RE.finditer(line.strip()):
            value = match.group("value").strip()
            fields.setdefault(match.group("key"), value)
    return fields


def log_paths(fields: Dict[str, str]) -> Dict[str, Optional[str]]:
    """Extract expanded stdout/stderr/workdir paths from an ``scontrol`` field map."""
    job_id = _clean(fields.get("JobId"))
    array_job_id = _clean(fields.get("ArrayJobId"))
    array_task_id = _clean(fields.get("ArrayTaskId"))
    context = {
        "j": job_id,
        "A": array_job_id or job_id,
        "a": array_task_id,
        "x": _clean(fields.get("JobName")),
        "u": _clean(fields.get("UserId", "").split("(")[0]) if fields.get("UserId") else None,
        "N": _first_node(_clean(fields.get("NodeList"))),
        "n": "0",
        "t": "0",
        "s": "0",
        "J": job_id,
        "X": "0",
    }
    return {
        "stdout_path": expand_filename_pattern(_clean(fields.get("StdOut")), context),
        "stderr_path": expand_filename_pattern(_clean(fields.get("StdErr")), context),
        "work_dir": _clean(fields.get("WorkDir")),
    }


def expand_filename_pattern(path: Optional[str], context: Dict[str, Optional[str]]) -> Optional[str]:
    """Expand Slurm filename patterns (``%j``, ``%A``, ``%x`` …) that survive into StdOut.

    Slurm 25.11's ``squeue --json`` returns the *unexpanded* pattern, so this is the difference
    between a usable log path and a literal ``%x-%A_%a.out``.

    If any token cannot be resolved — for example ``%a`` on an array job whose tasks have not
    been created yet — the whole path is reported as unavailable. A half-expanded path would
    only produce a confusing "file not found" further down.
    """
    if not path:
        return None

    def replace(match: re.Match) -> str:
        token = match.group(1)
        if token == "%":
            return "%"
        key = token[-1]
        width = token[:-1]
        value = context.get(key)
        if value is None:
            return match.group(0)
        if width.isdigit() and value.isdigit():
            return value.zfill(int(width))
        return value

    expanded = _FILENAME_PATTERN_RE.sub(replace, path)
    if _FILENAME_PATTERN_RE.search(expanded):
        return None
    return expanded


def _first_node(node_list: Optional[str]) -> Optional[str]:
    if not node_list:
        return None
    head = node_list.split(",", 1)[0]
    return head.split("[", 1)[0] or None


def _clean(value: Optional[Any]) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip()
    if is_empty(text):
        return None
    return text
