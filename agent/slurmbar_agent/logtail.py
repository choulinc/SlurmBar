"""Bounded log tail reading.

Job logs on HPC filesystems routinely reach gigabytes. Nothing here ever reads a whole file:
we seek to ``max(0, size - window)`` and read forward, so cost is bounded by the window rather
than by the file.

Control characters are stripped before the text leaves this module, so terminal escape
sequences from a training progress bar cannot reach the UI as live escapes.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import List, Optional

DEFAULT_WINDOW_BYTES = 128 * 1024
MAX_WINDOW_BYTES = 4 * 1024 * 1024
DEFAULT_MAX_LINES = 200
MAX_MAX_LINES = 5000
MAX_LINE_CHARS = 4000

# Keep tab; drop every other C0 control char plus DEL. \r and \n are handled by the splitter.
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


@dataclass
class TailResult:
    path: Optional[str]
    lines: List[str] = field(default_factory=list)
    bytes_read: Optional[int] = None
    file_size_bytes: Optional[int] = None
    truncated: bool = False
    modified_at: Optional[float] = None
    error: Optional[str] = None
    error_kind: Optional[str] = None  # "missing" | "permission" | "not_a_file" | "io"

    @property
    def ok(self) -> bool:
        return self.error is None


def sanitize(text: str) -> str:
    """Remove ANSI escapes and control characters, and bound the line length."""
    cleaned = _ANSI_RE.sub("", text)
    cleaned = _CONTROL_RE.sub("", cleaned)
    if len(cleaned) > MAX_LINE_CHARS:
        cleaned = cleaned[:MAX_LINE_CHARS] + " …[truncated]"
    return cleaned


def split_lines(blob: str) -> List[str]:
    """Split on newlines *and* carriage returns.

    tqdm and similar progress bars rewrite one physical line with ``\\r``. Treating ``\\r`` as a
    separator turns that single line into the sequence of states it passed through, which is
    exactly what a tail-based parser needs to see.
    """
    normalized = blob.replace("\r\n", "\n").replace("\r", "\n")
    return normalized.split("\n")


def read_tail(
    path: Optional[str],
    max_lines: int = DEFAULT_MAX_LINES,
    window_bytes: int = DEFAULT_WINDOW_BYTES,
) -> TailResult:
    """Read at most ``window_bytes`` from the end of ``path`` and return its last lines."""
    if not path:
        return TailResult(path=None, error="No log path is known for this job.", error_kind="missing")

    max_lines = max(1, min(int(max_lines), MAX_MAX_LINES))
    window_bytes = max(1024, min(int(window_bytes), MAX_WINDOW_BYTES))

    try:
        stat = os.stat(path)
    except FileNotFoundError:
        return TailResult(path=path, error="Log file does not exist.", error_kind="missing")
    except PermissionError:
        return TailResult(path=path, error="Permission denied reading the log file.", error_kind="permission")
    except OSError as exc:
        return TailResult(path=path, error=f"Could not stat the log file: {exc}", error_kind="io")

    if not os.path.isfile(path):
        return TailResult(path=path, error="Log path is not a regular file.", error_kind="not_a_file")

    size = stat.st_size
    start = max(0, size - window_bytes)
    try:
        with open(path, "rb") as handle:
            if start:
                handle.seek(start)
            blob = handle.read(window_bytes)
    except PermissionError:
        return TailResult(
            path=path,
            file_size_bytes=size,
            error="Permission denied reading the log file.",
            error_kind="permission",
        )
    except OSError as exc:
        return TailResult(
            path=path, file_size_bytes=size, error=f"Could not read the log file: {exc}", error_kind="io"
        )

    text = blob.decode("utf-8", errors="replace")
    lines = split_lines(text)
    # A window that started mid-file almost certainly cut the first line in half.
    if start and lines:
        lines = lines[1:]
    lines = [sanitize(line) for line in lines]
    # Drop the trailing empty element produced by a file ending in a newline.
    while lines and lines[-1] == "":
        lines.pop()

    truncated = start > 0
    if len(lines) > max_lines:
        lines = lines[-max_lines:]
        truncated = True

    return TailResult(
        path=path,
        lines=lines,
        bytes_read=len(blob),
        file_size_bytes=size,
        truncated=truncated,
        modified_at=stat.st_mtime,
    )
