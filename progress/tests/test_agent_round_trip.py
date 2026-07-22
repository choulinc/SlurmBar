"""The SDK writes; the agent reads. This test binds the two halves together.

If either side drifts — a renamed field, a changed timestamp format, a schema bump — this fails
even though both test suites pass in isolation.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from slurmbar_agent.progress import load_all
from slurmbar_agent.protocol import WarningCollector
from slurmbar_progress import ProgressReporter


@pytest.fixture
def warnings() -> WarningCollector:
    return WarningCollector()


def test_training_progress_round_trips(isolated_state_dir: Path, warnings):
    reporter = ProgressReporter(kind="training", job_id="201551", min_interval_seconds=0)
    reporter.update(
        current=375,
        total=1000,
        unit="epoch",
        phase="train",
        metrics={"loss": 0.059045, "learning_rate": 3.4e-05, "batch_current": 36, "batch_total": 94},
    )

    found = load_all(str(isolated_state_dir), ["201551"], warnings)
    progress = found["201551"]
    assert progress["source"] == "structured_file"
    assert progress["confidence"] == "high"
    assert progress["kind"] == "training"
    assert progress["phase"] == "train"
    assert (progress["current"], progress["total"]) == (375, 1000)
    assert progress["percent"] == 37.5
    assert progress["unit"] == "epoch"
    assert progress["metrics"]["loss"] == 0.059045
    assert progress["metrics"]["batch_current"] == 36
    assert progress["stale"] is False
    assert progress["updated_at"].endswith("Z")


def test_generic_counter_without_a_total_round_trips(isolated_state_dir: Path, warnings):
    reporter = ProgressReporter(kind="preprocessing", job_id="201570", min_interval_seconds=0)
    reporter.update(current=4820, unit="file", message="Converting parquet shards")

    progress = load_all(str(isolated_state_dir), ["201570"], warnings)["201570"]
    assert progress["kind"] == "preprocessing"
    assert progress["current"] == 4820
    assert progress["total"] is None
    assert progress["percent"] is None
    assert progress["eta_seconds"] is None
    assert progress["message"] == "Converting parquet shards"


def test_simulation_timesteps_round_trip(isolated_state_dir: Path, warnings):
    reporter = ProgressReporter(kind="simulation", job_id="201580", min_interval_seconds=0)
    reporter.update(current=4300, total=10000, unit="timestep", metrics={"residual": 1.2e-05})

    progress = load_all(str(isolated_state_dir), ["201580"], warnings)["201580"]
    assert progress["unit"] == "timestep"
    assert progress["percent"] == 43.0


def test_failure_state_round_trips_with_the_error(isolated_state_dir: Path, warnings):
    reporter = ProgressReporter(kind="training", job_id="201542", min_interval_seconds=0)
    reporter.update(current=812, total=1000, unit="epoch")
    reporter.fail(error="RuntimeError: CUDA out of memory")

    progress = load_all(str(isolated_state_dir), ["201542"], warnings)["201542"]
    assert progress["completion"] == "failed"
    assert "CUDA out of memory" in progress["error"]
    assert progress["current"] == 812
    assert progress["stale"] is False


def test_nan_loss_survives_the_round_trip(isolated_state_dir: Path, warnings):
    reporter = ProgressReporter(kind="training", job_id="201590", min_interval_seconds=0)
    reporter.update(current=5, total=10, metrics={"loss": float("nan")})

    progress = load_all(str(isolated_state_dir), ["201590"], warnings)["201590"]
    assert progress["metrics"]["loss"] == "nan"


def test_array_task_written_by_the_sdk_is_found_by_the_agent(
    isolated_state_dir: Path, warnings, monkeypatch
):
    monkeypatch.setenv("SLURM_ARRAY_JOB_ID", "201560")
    monkeypatch.setenv("SLURM_ARRAY_TASK_ID", "7")
    reporter = ProgressReporter(kind="sweep", min_interval_seconds=0)
    assert reporter.job_id == "201560_7"
    reporter.update(current=2, total=5, unit="trial")

    progress = load_all(str(isolated_state_dir), ["201560_7"], warnings)["201560_7"]
    assert progress["current"] == 2


def test_eta_is_computed_by_the_agent_from_sdk_timestamps(isolated_state_dir: Path, warnings):
    import json
    import time

    reporter = ProgressReporter(kind="training", job_id="201551", min_interval_seconds=0)
    reporter.update(current=1, total=100, unit="epoch")

    # Backdate the start so a measurable rate exists without sleeping in the test.
    path = Path(reporter.status_path)
    payload = json.loads(path.read_text())
    payload["started_at"] = "2026-07-22T00:00:00Z"
    payload["updated_at"] = "2026-07-22T01:00:00Z"
    payload["current"] = 25
    path.write_text(json.dumps(payload))

    from datetime import datetime, timezone

    now = datetime(2026, 7, 22, 1, 0, 5, tzinfo=timezone.utc)
    progress = load_all(str(isolated_state_dir), ["201551"], warnings, now=now)["201551"]
    # 25 epochs in 3600 s -> 75 remaining -> 10800 s.
    assert progress["eta_seconds"] == 10800
    del time
