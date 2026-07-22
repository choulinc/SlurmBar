"""Shared test setup.

The agent converts Slurm's timezone-naive timestamps using the *login node's* local zone, so
every test pins TZ=UTC before any datetime work happens. Without this, assertions on absolute
timestamps would depend on where the test runs.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

os.environ["TZ"] = "UTC"
if hasattr(time, "tzset"):
    time.tzset()

REPO_ROOT = Path(__file__).resolve().parents[2]
AGENT_ROOT = REPO_ROOT / "agent"
FIXTURES = REPO_ROOT / "fixtures"

for path in (str(AGENT_ROOT), str(REPO_ROOT / "progress")):
    if path not in sys.path:
        sys.path.insert(0, path)

import pytest  # noqa: E402


@pytest.fixture
def fixtures_dir() -> Path:
    return FIXTURES


def read_fixture(*parts: str) -> str:
    return (FIXTURES.joinpath(*parts)).read_text()
