"""``squeue`` collection: structured JSON first, machine-readable text as fallback.

Design notes:

* One ``squeue`` call per refresh. The app never asks for a job-at-a-time.
* ``--json`` is preferred, but its field shapes changed across Slurm 20.11 / 22.05 / 23.11
  (scalars became ``{"set","infinite","number"}`` wrappers, ``job_state`` became a list). All
  reads go through tolerant accessors instead of assuming one version.
* The text fallback uses ``-o`` with an explicit multi-character delimiter and puts free-text
  fields last. It never depends on column positions.
"""

from __future__ import annotations

import json
import re
from typing import Any, Dict, List, Optional, Sequence, Tuple

from .protocol import (
    MEM_REQUESTED_PER_CPU,
    MEM_REQUESTED_PER_NODE,
    MEM_REQUESTED_TOTAL,
    MEM_UNAVAILABLE,
    WarningCollector,
    W,
    empty_resources,
)
from .protocol import (
    STATE_COMPLETING,
    STATE_PENDING,
    STATE_RUNNING,
    STATE_SUSPENDED,
)
from .runner import CommandRunner
from .scontrol import expand_filename_pattern
from .states import normalize_state
from .timeutil import (
    is_empty,
    parse_duration_seconds,
    parse_memory,
    parse_minutes_to_seconds,
    parse_slurm_time,
    iso_utc,
    elapsed_between,
    parse_exit_code,
)

#: Delimiter for the text fallback. Three characters, none of which appear in practice in a
#: Slurm job name, reason or node list. A single ``|`` is not safe: job names may contain it.
FIELD_SEP = "|@|"

#: Field order for the text fallback. Free-text fields (nodelist, reason, name) are last so a
#: stray separator inside them cannot shift the meaning of any earlier field.
TEXT_FIELDS: Tuple[str, ...] = (
    "job_id",
    "array_job_id",
    "array_task_id",
    "partition",
    "state",
    "user",
    "elapsed",
    "time_limit",
    "node_count",
    "cpus",
    "min_memory",
    "tres_per_node",
    "submit_time",
    "start_time",
    "end_time",
    "account",
    "qos",
    "work_dir",
    "nodelist",
    "reason",
    "name",
)

_TEXT_FORMAT = FIELD_SEP.join(
    (
        "%i",  # job id (123 or 123_4)
        "%F",  # array job id
        "%K",  # array task id
        "%P",  # partition
        "%T",  # state, long form
        "%u",  # user
        "%M",  # elapsed
        "%l",  # time limit
        "%D",  # node count
        "%C",  # cpus
        "%m",  # minimum memory
        "%b",  # TRES per node (gres:gpu:2)
        "%V",  # submit time
        "%S",  # start time
        "%e",  # end time
        "%a",  # account
        "%q",  # qos
        "%Z",  # work dir
        "%N",  # node list
        "%r",  # reason
        "%j",  # job name (free text, last)
    )
)

_GPU_RE = re.compile(r"gpu[:\w]*?[:=](\d+)", re.IGNORECASE)
_NODE_RANGE_RE = re.compile(r"^(?P<prefix>.*?)\[(?P<ranges>[\d,\-]+)\](?P<suffix>.*)$")

#: `mem=` inside a TRES string such as `cpu=12,mem=80G,node=1,billing=12,gres/gpu=1`.
_TRES_MEM_RE = re.compile(r"(?:^|,)\s*mem=([0-9.]+[KMGTPE]?)", re.IGNORECASE)


def collect(
    runner: CommandRunner,
    user: Optional[str],
    warnings: WarningCollector,
    timeout: float = 15.0,
    prefer_json: bool = True,
) -> List[Dict[str, Any]]:
    """Return normalized job dicts for everything currently in the queue for ``user``."""
    if runner.which("squeue") is None:
        warnings.add(
            W.SLURM_MISSING,
            "squeue was not found on the login node.",
            severity="error",
            detail="Check that Slurm client commands are on PATH for non-interactive SSH sessions.",
        )
        return []

    if prefer_json:
        jobs = _try_json(runner, user, warnings, timeout)
        if jobs is not None:
            return jobs

    return _try_text(runner, user, warnings, timeout)


# ---------------------------------------------------------------------------------------------
# JSON path
# ---------------------------------------------------------------------------------------------


def _try_json(
    runner: CommandRunner, user: Optional[str], warnings: WarningCollector, timeout: float
) -> Optional[List[Dict[str, Any]]]:
    argv = ["squeue", "--json"]
    if user:
        argv += ["--user", user]
    result = runner.run(argv, timeout=timeout)
    if result.timed_out:
        warnings.add(W.COMMAND_TIMEOUT, "squeue --json timed out.", severity="error")
        return None
    if not result.ok or not result.stdout.strip():
        warnings.add(
            W.SQUEUE_JSON_UNSUPPORTED,
            "squeue --json is unavailable; using text output instead.",
            severity="info",
            detail=result.failure_summary(),
        )
        return None
    try:
        return parse_squeue_json(result.stdout, warnings)
    except ValueError as exc:
        warnings.add(
            W.SQUEUE_JSON_UNSUPPORTED,
            "squeue --json output could not be decoded; using text output instead.",
            severity="info",
            detail=str(exc),
        )
        return None


def parse_squeue_json(payload: str, warnings: WarningCollector) -> List[Dict[str, Any]]:
    """Parse ``squeue --json``. Raises ``ValueError`` when the payload is not usable at all."""
    try:
        document = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON: {exc}") from exc
    if not isinstance(document, dict):
        raise ValueError("expected a JSON object at the top level")
    raw_jobs = document.get("jobs")
    if not isinstance(raw_jobs, list):
        raise ValueError("missing 'jobs' array")

    jobs: List[Dict[str, Any]] = []
    for entry in raw_jobs:
        if not isinstance(entry, dict):
            continue
        try:
            jobs.append(_job_from_json(entry))
        except Exception as exc:  # one bad record must not lose the whole queue
            warnings.add(
                W.PARTIAL_DATA,
                "A squeue record could not be parsed and was skipped.",
                detail=f"{type(exc).__name__}: {exc}",
            )
    return jobs


def _num(value: Any) -> Optional[int]:
    """Read a Slurm JSON scalar that may be plain or wrapped in {set,infinite,number}."""
    if isinstance(value, dict):
        if not value.get("set", True) or value.get("infinite"):
            return None
        value = value.get("number")
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _text(value: Any) -> Optional[str]:
    if isinstance(value, dict):
        value = value.get("string") or value.get("name")
    if value is None:
        return None
    if isinstance(value, (list, tuple)):
        parts = [str(item) for item in value if item not in (None, "")]
        value = ",".join(parts)
    text = str(value).strip()
    if is_empty(text):
        return None
    return text


def _job_from_json(entry: Dict[str, Any]) -> Dict[str, Any]:
    array_job_id = _num(entry.get("array_job_id"))
    array_task_id = _num(entry.get("array_task_id"))
    raw_job_id = _num(entry.get("job_id"))

    if array_task_id is not None and array_job_id:
        job_id = f"{array_job_id}_{array_task_id}"
    else:
        job_id = str(raw_job_id if raw_job_id is not None else _text(entry.get("job_id")) or "")

    state, state_raw = normalize_state(entry.get("job_state"))

    submit = parse_slurm_time(entry.get("submit_time"))
    start = parse_slurm_time(entry.get("start_time"))
    end = parse_slurm_time(entry.get("end_time"))

    # For a running job, squeue's end_time is the *projected* end. Elapsed must not use it.
    elapsed = elapsed_between(start, end if state not in ("RUNNING", "COMPLETING") else None)

    node_list = _text(entry.get("nodes")) or _text(entry.get("node_list"))
    nodes = expand_node_list(node_list)

    gpus = _gpu_count(
        _text(entry.get("tres_per_node")),
        _text(entry.get("tres_per_job")),
        _text(entry.get("tres_alloc_str")),
        _text(entry.get("tres_req_str")),
    )

    resources = empty_resources()
    # TRES is the authoritative record of what the job actually asked for and got. Some Slurm
    # versions report `memory_per_node` as a node-level figure unrelated to an individual job's
    # request, so TRES is consulted first and the per-node/per-CPU fields are only a fallback.
    tres_memory = _memory_from_tres(
        _text(entry.get("tres_alloc_str")), _text(entry.get("tres_req_str"))
    )
    mem_per_node = _num(entry.get("memory_per_node"))
    mem_per_cpu = _num(entry.get("memory_per_cpu"))
    if tres_memory is not None:
        resources["memory_limit_bytes"] = tres_memory
        # Slurm reports TRES as the aggregate for the whole allocation.
        resources["memory_limit_semantics"] = MEM_REQUESTED_TOTAL
    elif mem_per_node:
        resources["memory_limit_bytes"] = mem_per_node * 1024 * 1024
        resources["memory_limit_semantics"] = MEM_REQUESTED_PER_NODE
    elif mem_per_cpu:
        resources["memory_limit_bytes"] = mem_per_cpu * 1024 * 1024
        resources["memory_limit_semantics"] = MEM_REQUESTED_PER_CPU

    # Slurm reports exit_code 0 for jobs that have not exited. A job that is still running has
    # no exit status, and claiming "exit 0" for it is simply false.
    exit_code, signal = parse_exit_code(entry.get("exit_code"))
    if state in (STATE_PENDING, STATE_RUNNING, STATE_SUSPENDED, STATE_COMPLETING):
        exit_code, signal = None, None

    # Slurm may return the filename *pattern* rather than the resolved path.
    raw_stdout = _text(entry.get("standard_output"))
    raw_stderr = _text(entry.get("standard_error"))
    pattern_context = {
        "j": str(raw_job_id) if raw_job_id is not None else None,
        "A": str(array_job_id) if array_job_id else (str(raw_job_id) if raw_job_id is not None else None),
        "a": str(array_task_id) if array_task_id is not None else None,
        "x": _text(entry.get("name")),
        "u": _text(entry.get("user_name")),
        "N": nodes[0] if nodes else None,
        "n": "0",
        "t": "0",
        "s": "0",
        "J": str(raw_job_id) if raw_job_id is not None else None,
        "X": "0",
    }

    return {
        "job_id": job_id,
        # The id Slurm uses internally. For an array task this differs from the display id
        # ("500103_0" vs 500100) and it is what sstat answers with.
        "slurm_job_id": str(raw_job_id) if raw_job_id is not None else None,
        "array_job_id": str(array_job_id) if array_job_id and array_task_id is not None else None,
        "array_task_id": str(array_task_id) if array_task_id is not None else None,
        "name": _text(entry.get("name")) or job_id,
        "user": _text(entry.get("user_name")),
        "account": _text(entry.get("account")),
        "partition": _text(entry.get("partition")),
        "qos": _text(entry.get("qos")),
        "state": state,
        "state_raw": state_raw,
        "reason": _pending_reason(state, _text(entry.get("state_reason"))),
        "submit_time": iso_utc(submit),
        "start_time": iso_utc(start),
        "end_time": iso_utc(end) if state not in ("RUNNING", "COMPLETING", "PENDING") else None,
        "elapsed_seconds": elapsed,
        "time_limit_seconds": parse_minutes_to_seconds(entry.get("time_limit")),
        "nodes": nodes,
        "node_count": _num(entry.get("node_count")),
        "cpus": _num(entry.get("cpus")),
        "gpus": gpus,
        "work_dir": _text(entry.get("current_working_directory")),
        "stdout_path": expand_filename_pattern(raw_stdout, pattern_context),
        "stderr_path": expand_filename_pattern(raw_stderr, pattern_context),
        "exit_code": exit_code,
        "signal": signal,
        "source": "squeue",
        "resources": resources,
        "progress": None,
    }


# ---------------------------------------------------------------------------------------------
# Text fallback
# ---------------------------------------------------------------------------------------------


def _try_text(
    runner: CommandRunner, user: Optional[str], warnings: WarningCollector, timeout: float
) -> List[Dict[str, Any]]:
    argv = ["squeue", "--noheader", "-o", _TEXT_FORMAT]
    if user:
        argv += ["--user", user]
    result = runner.run(argv, timeout=timeout)
    if result.timed_out:
        warnings.add(W.COMMAND_TIMEOUT, "squeue timed out.", severity="error")
        return []
    if not result.ok:
        warnings.add(
            W.SQUEUE_FAILED,
            "squeue failed; the job queue could not be read.",
            severity="error",
            detail=result.failure_summary(),
        )
        return []
    return parse_squeue_text(result.stdout, warnings)


def parse_squeue_text(payload: str, warnings: WarningCollector) -> List[Dict[str, Any]]:
    jobs: List[Dict[str, Any]] = []
    for line in payload.splitlines():
        if not line.strip():
            continue
        parts = line.split(FIELD_SEP)
        if len(parts) != len(TEXT_FIELDS):
            warnings.add(
                W.SQUEUE_TEXT_UNPARSABLE,
                "A squeue line had an unexpected field count and was skipped.",
                detail=f"expected {len(TEXT_FIELDS)} fields, got {len(parts)}",
            )
            continue
        row = dict(zip(TEXT_FIELDS, (p.strip() for p in parts)))
        try:
            jobs.append(_job_from_text_row(row))
        except Exception as exc:
            warnings.add(
                W.SQUEUE_TEXT_UNPARSABLE,
                "A squeue line could not be parsed and was skipped.",
                detail=f"{type(exc).__name__}: {exc}",
            )
    return jobs


def _job_from_text_row(row: Dict[str, str]) -> Dict[str, Any]:
    job_id = row["job_id"]
    array_task_id = row.get("array_task_id") or ""
    array_job_id = row.get("array_job_id") or ""
    is_array_task = bool(array_task_id) and not is_empty(array_task_id) and "_" in job_id

    state, state_raw = normalize_state(row.get("state"))
    submit = parse_slurm_time(row.get("submit_time"))
    start = parse_slurm_time(row.get("start_time"))
    end = parse_slurm_time(row.get("end_time"))

    elapsed = parse_duration_seconds(row.get("elapsed"))
    if elapsed is None:
        elapsed = elapsed_between(start, None if state in ("RUNNING", "COMPLETING") else end)

    memory = parse_memory(row.get("min_memory"), default_unit="M")
    resources = empty_resources()
    if memory.bytes:
        resources["memory_limit_bytes"] = memory.bytes
        resources["memory_limit_semantics"] = {
            "c": MEM_REQUESTED_PER_CPU,
            "n": MEM_REQUESTED_PER_NODE,
        }.get(memory.per or "", MEM_REQUESTED_TOTAL)
    else:
        resources["memory_limit_semantics"] = MEM_UNAVAILABLE

    return {
        "job_id": job_id,
        # squeue's -o format has no column for the underlying id, so array-task sstat matching
        # falls back to the array parent in text mode.
        "slurm_job_id": None,
        "array_job_id": array_job_id if is_array_task and not is_empty(array_job_id) else None,
        "array_task_id": array_task_id if is_array_task else None,
        "name": row.get("name") or job_id,
        "user": _none_if_empty(row.get("user")),
        "account": _none_if_empty(row.get("account")),
        "partition": _none_if_empty(row.get("partition")),
        "qos": _none_if_empty(row.get("qos")),
        "state": state,
        "state_raw": state_raw,
        "reason": _pending_reason(state, _none_if_empty(row.get("reason"))),
        "submit_time": iso_utc(submit),
        "start_time": iso_utc(start),
        "end_time": iso_utc(end) if state not in ("RUNNING", "COMPLETING", "PENDING") else None,
        "elapsed_seconds": elapsed,
        "time_limit_seconds": parse_duration_seconds(row.get("time_limit")),
        "nodes": expand_node_list(_none_if_empty(row.get("nodelist"))),
        "node_count": _int_or_none(row.get("node_count")),
        "cpus": _int_or_none(row.get("cpus")),
        "gpus": _gpu_count(row.get("tres_per_node")),
        "work_dir": _none_if_empty(row.get("work_dir")),
        "stdout_path": None,  # not exposed by squeue -o; resolved on demand via scontrol
        "stderr_path": None,
        "exit_code": None,
        "signal": None,
        "source": "squeue",
        "resources": resources,
        "progress": None,
    }


# ---------------------------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------------------------


def _memory_from_tres(*tres_values: Optional[str]) -> Optional[int]:
    """Extract `mem=` from a TRES string as bytes, or None when absent."""
    for value in tres_values:
        if not value or is_empty(value):
            continue
        match = _TRES_MEM_RE.search(value)
        if not match:
            continue
        parsed = parse_memory(match.group(1), default_unit="M")
        if parsed.bytes is not None:
            return parsed.bytes
    return None


def _none_if_empty(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    text = value.strip()
    return None if is_empty(text) else text


def _int_or_none(value: Any) -> Optional[int]:
    if is_empty(value):
        return None
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def _pending_reason(state: str, reason: Optional[str]) -> Optional[str]:
    if reason is None:
        return None
    if reason.lower() in ("none", "(null)", "null"):
        return None
    return reason


def _gpu_count(*tres_values: Optional[str]) -> Optional[int]:
    """Extract a GPU count from any of the TRES strings Slurm might provide.

    Only reports what Slurm already said. The agent never launches ``nvidia-smi``.
    """
    for value in tres_values:
        if not value or is_empty(value):
            continue
        match = _GPU_RE.search(value)
        if match:
            try:
                return int(match.group(1))
            except ValueError:
                continue
        # "gres/gpu=2" and bare "gpu:2"
        alt = re.search(r"gpu[^\d]{0,12}?(\d+)", value, re.IGNORECASE)
        if alt:
            try:
                return int(alt.group(1))
            except ValueError:
                continue
    return None


def expand_node_list(node_list: Optional[str]) -> List[str]:
    """Expand Slurm's compact host list, e.g. ``h200-[017-019,021]`` -> four host names.

    Falls back to returning the raw string as a single element if the form is unfamiliar; the
    UI would rather show something truthful than nothing.
    """
    if not node_list or is_empty(node_list):
        return []
    text = node_list.strip()
    out: List[str] = []
    for chunk in _split_top_level(text):
        match = _NODE_RANGE_RE.match(chunk)
        if not match:
            out.append(chunk)
            continue
        prefix = match.group("prefix")
        suffix = match.group("suffix")
        for piece in match.group("ranges").split(","):
            if "-" in piece:
                low_s, _, high_s = piece.partition("-")
                if not (low_s.isdigit() and high_s.isdigit()):
                    out.append(chunk)
                    break
                width = len(low_s)
                low, high = int(low_s), int(high_s)
                if high < low or high - low > 4096:
                    out.append(chunk)
                    break
                out.extend(f"{prefix}{n:0{width}d}{suffix}" for n in range(low, high + 1))
            elif piece.isdigit():
                out.append(f"{prefix}{piece}{suffix}")
            elif piece:
                out.append(chunk)
    return out


def _split_top_level(text: str) -> List[str]:
    """Split on commas that are not inside ``[...]``."""
    parts: List[str] = []
    depth = 0
    current: List[str] = []
    for char in text:
        if char == "[":
            depth += 1
        elif char == "]":
            depth = max(0, depth - 1)
        if char == "," and depth == 0:
            if current:
                parts.append("".join(current).strip())
                current = []
            continue
        current.append(char)
    if current:
        parts.append("".join(current).strip())
    return [p for p in parts if p]
