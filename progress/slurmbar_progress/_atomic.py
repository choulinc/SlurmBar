"""Atomic JSON writing for shared (often networked) filesystems.

The agent may read ``status.json`` at any moment, including mid-write. Writing to a temporary
file in the same directory and then ``os.replace``-ing it means a reader either sees the whole
previous document or the whole new one — never a torn one. ``os.replace`` is atomic within a
directory on POSIX, which is why the temporary file must be a sibling, not in ``/tmp``.
"""

from __future__ import annotations

import errno
import json
import os
import tempfile
from typing import Any, Dict


def atomic_write_json(path: str, payload: Dict[str, Any], fsync: bool = True) -> None:
    """Serialize ``payload`` and atomically replace ``path``.

    ``fsync`` is worth the cost on a local filesystem and is usually a no-op-ish on Lustre/GPFS,
    but it can be disabled for very high update rates.
    """
    directory = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(directory, exist_ok=True)

    # ensure_ascii keeps the file byte-safe across locales; default=str stops an exotic metric
    # value from raising in the middle of a training loop.
    text = json.dumps(payload, ensure_ascii=True, default=str, separators=(",", ":"))

    fd, tmp_path = tempfile.mkstemp(prefix=".status-", suffix=".json.tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            if fsync:
                try:
                    os.fsync(handle.fileno())
                except OSError:
                    # Some network filesystems refuse fsync; the replace below is still atomic.
                    pass
        os.replace(tmp_path, path)
        tmp_path = ""  # ownership transferred
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError as exc:  # pragma: no cover - cleanup best effort
                if exc.errno != errno.ENOENT:
                    pass
