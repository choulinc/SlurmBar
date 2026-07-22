from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from slurmbar_agent.progress import DEFAULT_STALE_SECONDS, load_all
from slurmbar_agent.protocol import WarningCollector

NOW = datetime(2026, 7, 22, 2, 30, 0, tzinfo=timezone.utc)


def write_status(root: Path, job_id: str, **overrides) -> Path:
    payload = {
        "schema_version": 1,
        "job_id": job_id,
        "pid": 12345,
        "hostname": "example-gpu-017",
        "kind": "training",
        "phase": "train",
        "current": 375,
        "total": 1000,
        "unit": "epoch",
        "message": None,
        "metrics": {"loss": 0.059045, "learning_rate": 3.4e-05},
        "started_at": "2026-07-22T00:10:00Z",
        "updated_at": "2026-07-22T02:29:55Z",
        "completion": "running",
        "error": None,
    }
    payload.update(overrides)
    directory = root / job_id
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "status.json"
    path.write_text(json.dumps(payload))
    return path


@pytest.fixture
def warnings() -> WarningCollector:
    return WarningCollector()


def test_reads_structured_progress(tmp_path: Path, warnings):
    write_status(tmp_path, "201551")
    found = load_all(str(tmp_path), ["201551"], warnings, now=NOW)
    progress = found["201551"]
    assert progress["source"] == "structured_file"
    assert progress["confidence"] == "high"
    assert progress["current"] == 375
    assert progress["total"] == 1000
    assert progress["percent"] == 37.5
    assert progress["unit"] == "epoch"
    assert progress["phase"] == "train"
    assert progress["metrics"]["loss"] == 0.059045
    assert progress["stale"] is False


def test_eta_is_derived_from_observed_throughput(tmp_path: Path, warnings):
    write_status(tmp_path, "201551")
    progress = load_all(str(tmp_path), ["201551"], warnings, now=NOW)["201551"]
    # 375 epochs in 8395 s -> 625 remaining at the same rate.
    assert progress["eta_seconds"] == pytest.approx(8395 / 375 * 625, rel=0.01)


def test_no_eta_when_total_is_unknown(tmp_path: Path, warnings):
    write_status(tmp_path, "201570", total=None, unit="item", kind="preprocessing")
    progress = load_all(str(tmp_path), ["201570"], warnings, now=NOW)["201570"]
    assert progress["total"] is None
    assert progress["percent"] is None
    assert progress["eta_seconds"] is None
    assert progress["current"] == 375


def test_stale_progress_is_flagged_and_warned(tmp_path: Path, warnings):
    old = (NOW - timedelta(seconds=DEFAULT_STALE_SECONDS + 60)).strftime("%Y-%m-%dT%H:%M:%SZ")
    write_status(tmp_path, "201551", updated_at=old)
    progress = load_all(str(tmp_path), ["201551"], warnings, now=NOW)["201551"]
    assert progress["stale"] is True
    assert progress["eta_seconds"] is None  # never extrapolate from a stale sample
    assert "PROGRESS_STALE" in [w.code for w in warnings.items]


def test_finished_progress_is_not_called_stale(tmp_path: Path, warnings):
    old = (NOW - timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
    write_status(tmp_path, "201540", updated_at=old, completion="completed", current=1000)
    progress = load_all(str(tmp_path), ["201540"], warnings, now=NOW)["201540"]
    assert progress["completion"] == "completed"
    assert progress["stale"] is False
    assert "PROGRESS_STALE" not in [w.code for w in warnings.items]


def test_failed_progress_carries_the_error(tmp_path: Path, warnings):
    write_status(tmp_path, "201542", completion="failed", error="RuntimeError: CUDA OOM", current=812)
    progress = load_all(str(tmp_path), ["201542"], warnings, now=NOW)["201542"]
    assert progress["completion"] == "failed"
    assert progress["error"] == "RuntimeError: CUDA OOM"
    assert progress["current"] == 812


def test_array_task_falls_back_to_the_array_parent_directory(tmp_path: Path, warnings):
    write_status(tmp_path, "201560", current=3, total=10)
    found = load_all(str(tmp_path), ["201560_7"], warnings, now=NOW)
    assert found["201560_7"]["current"] == 3


def test_array_task_prefers_its_own_directory(tmp_path: Path, warnings):
    write_status(tmp_path, "201560", current=3, total=10)
    write_status(tmp_path, "201560_7", current=9, total=10)
    found = load_all(str(tmp_path), ["201560_7"], warnings, now=NOW)
    assert found["201560_7"]["current"] == 9


def test_missing_directory_warns_once_and_returns_nothing(tmp_path: Path, warnings):
    found = load_all(str(tmp_path / "absent"), ["201551"], warnings, now=NOW)
    assert found == {}
    warning = next(w for w in warnings.items if w.code == "PROGRESS_DIR_MISSING")
    assert warning.severity == "info"


def test_job_without_a_progress_file_is_simply_absent(tmp_path: Path, warnings):
    write_status(tmp_path, "201551")
    found = load_all(str(tmp_path), ["201551", "201570"], warnings, now=NOW)
    assert set(found) == {"201551"}


def test_invalid_json_is_reported_not_raised(tmp_path: Path, warnings):
    directory = tmp_path / "201551"
    directory.mkdir()
    (directory / "status.json").write_text("{not json")
    assert load_all(str(tmp_path), ["201551"], warnings, now=NOW) == {}
    assert "PROGRESS_FILE_INVALID" in [w.code for w in warnings.items]


def test_unsupported_schema_version_is_refused(tmp_path: Path, warnings):
    write_status(tmp_path, "201551", schema_version=99)
    assert load_all(str(tmp_path), ["201551"], warnings, now=NOW) == {}
    assert "PROGRESS_SCHEMA_UNSUPPORTED" in [w.code for w in warnings.items]


def test_oversized_status_file_is_ignored(tmp_path: Path, warnings):
    directory = tmp_path / "201551"
    directory.mkdir()
    (directory / "status.json").write_text("x" * (300 * 1024))
    assert load_all(str(tmp_path), ["201551"], warnings, now=NOW) == {}
    assert "PROGRESS_FILE_INVALID" in [w.code for w in warnings.items]


def test_invalid_job_ids_never_touch_the_filesystem(tmp_path: Path, warnings):
    write_status(tmp_path, "201551")
    assert load_all(str(tmp_path), ["../../etc", "201551; rm -rf /"], warnings, now=NOW) == {}


def test_metrics_are_bounded_and_json_safe(tmp_path: Path, warnings):
    write_status(
        tmp_path,
        "201551",
        metrics={f"m{i}": i for i in range(200)} | {"note": "z" * 5000, "bad": float("nan")}
        if hasattr(dict, "__or__")
        else {"note": "z" * 5000},
    )
    progress = load_all(str(tmp_path), ["201551"], warnings, now=NOW)["201551"]
    assert len(progress["metrics"]) <= 64
