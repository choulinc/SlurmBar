from __future__ import annotations

import os
import sys
import time
from pathlib import Path

os.environ["TZ"] = "UTC"
if hasattr(time, "tzset"):
    time.tzset()

REPO_ROOT = Path(__file__).resolve().parents[2]
for path in (str(REPO_ROOT / "progress"), str(REPO_ROOT / "agent")):
    if path not in sys.path:
        sys.path.insert(0, path)

import pytest  # noqa: E402


@pytest.fixture(autouse=True)
def isolated_state_dir(tmp_path, monkeypatch):
    """Never let a test write into the developer's real ~/.local/state/slurmbar."""
    state = tmp_path / "state"
    monkeypatch.setenv("SLURMBAR_STATE_DIR", str(state))
    for name in ("SLURM_JOB_ID", "SLURM_JOBID", "SLURM_ARRAY_JOB_ID", "SLURM_ARRAY_TASK_ID"):
        monkeypatch.delenv(name, raising=False)
    return state
