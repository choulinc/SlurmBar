"""End-to-end snapshot assembly against a fake command runner.

These tests are the closest thing to "does the agent work" without a live cluster: they drive
the real parsing, merging and progress code with recorded Slurm output.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from conftest import read_fixture
from slurmbar_agent.runner import FakeRunner
from slurmbar_agent.snapshot import build_snapshot


def full_runner() -> FakeRunner:
    runner = FakeRunner()
    runner.stub("squeue --json", read_fixture("squeue", "squeue-json-2311.json"))
    runner.stub(
        "sacct --noheader --parsable2 --allocations",
        read_fixture("sacct", "sacct-allocations.txt"),
    )
    # The step-memory query differs from the allocation query only by the absence of
    # --allocations, so the stub key must include the next argv element to stay unambiguous.
    runner.stub(
        "sacct --noheader --parsable2 --starttime=now-24hours",
        read_fixture("sacct", "sacct-steps.txt"),
    )
    runner.stub("sstat", read_fixture("sstat", "sstat-running.txt"))
    runner.stub("scontrol show config", "ClusterName            = examplecluster\nSLURM_VERSION          = 23.11.7\n")
    return runner


@pytest.fixture
def snapshot(tmp_path: Path):
    return build_snapshot(full_runner(), user="exampleuser", progress_dir=str(tmp_path))


class TestSnapshotShape:
    def test_protocol_envelope(self, snapshot):
        assert snapshot["schema_version"] == 1
        assert snapshot["generated_at"].endswith("Z")
        assert set(snapshot) >= {"cluster", "summary", "jobs", "warnings"}

    def test_cluster_identity_comes_from_one_scontrol_call(self, snapshot):
        assert snapshot["cluster"]["name"] == "examplecluster"
        assert snapshot["cluster"]["slurm_version"] == "23.11.7"

    def test_summary_counts(self, snapshot):
        summary = snapshot["summary"]
        assert summary["running"] == 2
        assert summary["pending"] == 1
        assert summary["completed_recently"] == 1
        assert summary["failed_recently"] == 3  # FAILED, TIMEOUT, OUT_OF_MEMORY
        assert summary["completing"] == 0

    def test_is_json_serializable(self, snapshot):
        json.dumps(snapshot)


class TestMerging:
    def test_queue_and_history_are_combined_without_duplicates(self, snapshot):
        ids = [job["job_id"] for job in snapshot["jobs"]]
        assert len(ids) == len(set(ids))
        assert "201551" in ids  # in both squeue and sacct
        assert "201540" in ids  # sacct only
        assert "201560_7" in ids  # squeue only

    def test_live_record_wins_over_accounting(self, snapshot):
        job = next(j for j in snapshot["jobs"] if j["job_id"] == "201551")
        assert job["source"] == "squeue"
        assert job["state"] == "RUNNING"

    def test_running_job_gets_live_memory_from_sstat_labelled_as_peak(self, snapshot):
        job = next(j for j in snapshot["jobs"] if j["job_id"] == "201551")
        assert job["resources"]["memory_used_bytes"] == 118111600 * 1024
        assert job["resources"]["memory_semantics"] == "peak_rss"
        assert job["resources"]["memory_limit_semantics"] == "requested_per_node"

    def test_finished_job_memory_is_labelled_per_step_peak(self, snapshot):
        job = next(j for j in snapshot["jobs"] if j["job_id"] == "201540")
        assert job["resources"]["memory_semantics"] == "peak_rss_per_step"

    def test_gpu_metrics_only_appear_when_slurm_reported_them(self, snapshot):
        with_gpu = next(j for j in snapshot["jobs"] if j["job_id"] == "201551")
        assert with_gpu["resources"]["gpu_memory_used_bytes"] == 40265 * 1024**2
        assert with_gpu["resources"]["gpu_utilization_percent"] == 87.0

        without_gpu = next(j for j in snapshot["jobs"] if j["job_id"] == "201570")
        assert without_gpu["resources"]["gpu_memory_used_bytes"] is None
        assert without_gpu["resources"]["gpu_utilization_percent"] is None


class TestCommandBudget:
    def test_no_per_job_slurm_calls(self, tmp_path: Path):
        runner = full_runner()
        build_snapshot(runner, user="exampleuser", progress_dir=str(tmp_path))
        # squeue, sacct allocations, sacct steps, sstat, scontrol show config.
        assert len(runner.calls) == 5
        assert not any("scontrol" in c and "show" in c and "job" in c for c in runner.calls)

    def test_sstat_can_be_disabled(self, tmp_path: Path):
        runner = full_runner()
        build_snapshot(runner, user="exampleuser", progress_dir=str(tmp_path), enable_sstat=False)
        assert not any(call[0] == "sstat" for call in runner.calls)


class TestDegradedClusters:
    def test_no_accounting_still_returns_the_live_queue(self, tmp_path: Path):
        runner = FakeRunner(available=["squeue", "scontrol"])
        runner.stub("squeue --json", read_fixture("squeue", "squeue-json-2311.json"))
        runner.stub("scontrol show config", "ClusterName = examplecluster\n")
        snapshot = build_snapshot(runner, user="exampleuser", progress_dir=str(tmp_path))
        assert len(snapshot["jobs"]) == 3
        assert snapshot["summary"]["completed_recently"] == 0
        codes = {w["code"] for w in snapshot["warnings"]}
        assert "SACCT_UNAVAILABLE" in codes

    def test_no_slurm_at_all_is_an_empty_snapshot_with_an_error_warning(self, tmp_path: Path):
        runner = FakeRunner(available=[])
        snapshot = build_snapshot(runner, user="exampleuser", progress_dir=str(tmp_path))
        assert snapshot["jobs"] == []
        warning = next(w for w in snapshot["warnings"] if w["code"] == "SLURM_MISSING")
        assert warning["severity"] == "error"

    def test_text_fallback_produces_a_usable_snapshot(self, tmp_path: Path):
        runner = FakeRunner()
        runner.stub("squeue --json", "", returncode=1, stderr="unrecognized option '--json'")
        runner.stub("squeue --noheader", read_fixture("squeue", "squeue-text.txt"))
        runner.stub("sacct", "")
        runner.stub("sstat", "")
        runner.stub("scontrol show config", "ClusterName = examplecluster\n")
        snapshot = build_snapshot(runner, user="exampleuser", progress_dir=str(tmp_path))
        assert snapshot["summary"]["running"] == 2
        assert snapshot["summary"]["pending"] == 1
        assert snapshot["summary"]["completing"] == 1

    def test_partial_data_is_returned_with_warnings_rather_than_failing(self, tmp_path: Path):
        runner = FakeRunner()
        runner.stub("squeue --json", read_fixture("squeue", "squeue-json-2311.json"))
        runner.stub("sacct", "", returncode=1, stderr="sacct: error: Problem talking to the database")
        runner.stub_timeout("sstat")
        runner.stub("scontrol show config", "")
        snapshot = build_snapshot(runner, user="exampleuser", progress_dir=str(tmp_path))
        assert len(snapshot["jobs"]) == 3
        codes = {w["code"] for w in snapshot["warnings"]}
        assert "SACCT_FAILED" in codes
        assert "COMMAND_TIMEOUT" in codes


class TestProgressIntegration:
    def _write_progress(self, root: Path, job_id: str, **overrides):
        payload = {
            "schema_version": 1,
            "job_id": job_id,
            "kind": "training",
            "phase": "train",
            "current": 375,
            "total": 1000,
            "unit": "epoch",
            "metrics": {"loss": 0.059045},
            "started_at": "2026-07-22T00:10:00Z",
            "updated_at": "2026-07-22T02:29:55Z",
            "completion": "running",
        }
        payload.update(overrides)
        directory = root / job_id
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "status.json").write_text(json.dumps(payload))

    def test_structured_progress_is_attached_to_the_matching_job(self, tmp_path: Path):
        self._write_progress(tmp_path, "201551")
        snapshot = build_snapshot(full_runner(), user="exampleuser", progress_dir=str(tmp_path))
        job = next(j for j in snapshot["jobs"] if j["job_id"] == "201551")
        assert job["progress"]["source"] == "structured_file"
        assert job["progress"]["percent"] == 37.5
        assert job["progress"]["metrics"]["loss"] == 0.059045

    def test_jobs_without_progress_still_appear_with_slurm_state(self, tmp_path: Path):
        snapshot = build_snapshot(full_runner(), user="exampleuser", progress_dir=str(tmp_path))
        job = next(j for j in snapshot["jobs"] if j["job_id"] == "201570")
        assert job["progress"] is None
        assert job["state"] == "RUNNING"
        assert job["elapsed_seconds"] is not None

    def test_structured_progress_beats_the_log_parser(self, tmp_path: Path, monkeypatch):
        log = tmp_path / "job.log"
        log.write_text("Epoch 900/1000\n")
        self._write_progress(tmp_path, "201551")

        runner = full_runner()
        snapshot = build_snapshot(runner, user="exampleuser", progress_dir=str(tmp_path))
        job = next(j for j in snapshot["jobs"] if j["job_id"] == "201551")
        assert job["progress"]["source"] == "structured_file"
        assert job["progress"]["current"] == 375

    def test_log_fallback_fills_in_when_no_structured_progress_exists(self, tmp_path: Path):
        log = tmp_path / "slurm-201551.out"
        log.write_text("Epoch 42/100 loss=0.51\n")

        payload = json.loads(read_fixture("squeue", "squeue-json-2311.json"))
        payload["jobs"][0]["standard_output"] = str(log)
        runner = full_runner()
        runner.stub("squeue --json", json.dumps(payload))

        snapshot = build_snapshot(runner, user="exampleuser", progress_dir=str(tmp_path / "empty"))
        job = next(j for j in snapshot["jobs"] if j["job_id"] == "201551")
        assert job["progress"]["source"] == "log_parser"
        assert job["progress"]["confidence"] == "medium"
        assert job["progress"]["percent"] == 42.0

    def test_log_fallback_can_be_disabled(self, tmp_path: Path):
        log = tmp_path / "slurm-201551.out"
        log.write_text("Epoch 42/100\n")
        payload = json.loads(read_fixture("squeue", "squeue-json-2311.json"))
        payload["jobs"][0]["standard_output"] = str(log)
        runner = full_runner()
        runner.stub("squeue --json", json.dumps(payload))

        snapshot = build_snapshot(
            runner, user="exampleuser", progress_dir=str(tmp_path / "empty"), enable_log_fallback=False
        )
        job = next(j for j in snapshot["jobs"] if j["job_id"] == "201551")
        assert job["progress"] is None

    def test_progress_from_a_failed_job_is_preserved(self, tmp_path: Path):
        self._write_progress(
            tmp_path, "201542", completion="failed", error="CUDA out of memory", current=812
        )
        snapshot = build_snapshot(full_runner(), user="exampleuser", progress_dir=str(tmp_path))
        job = next(j for j in snapshot["jobs"] if j["job_id"] == "201542")
        assert job["state"] == "FAILED"
        assert job["progress"]["completion"] == "failed"
        assert job["progress"]["current"] == 812
