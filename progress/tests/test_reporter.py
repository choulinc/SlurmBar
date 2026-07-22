from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from slurmbar_progress import ProgressReporter, default_state_dir, detect_job_id


def read_status(reporter: ProgressReporter) -> dict:
    return json.loads(Path(reporter.status_path).read_text())


# ---------------------------------------------------------------------------------------------
# Job identity
# ---------------------------------------------------------------------------------------------


class TestJobIdentity:
    def test_uses_slurm_job_id_when_present(self, monkeypatch):
        monkeypatch.setenv("SLURM_JOB_ID", "201551")
        assert detect_job_id() == "201551"

    def test_legacy_slurm_jobid_spelling(self, monkeypatch):
        monkeypatch.setenv("SLURM_JOBID", "201551")
        assert detect_job_id() == "201551"

    def test_array_tasks_use_the_queue_visible_form(self, monkeypatch):
        monkeypatch.setenv("SLURM_JOB_ID", "201567")
        monkeypatch.setenv("SLURM_ARRAY_JOB_ID", "201560")
        monkeypatch.setenv("SLURM_ARRAY_TASK_ID", "7")
        # squeue shows 201560_7, so that is the id SlurmBar must match on.
        assert detect_job_id() == "201560_7"

    def test_works_outside_slurm_for_local_testing(self):
        assert detect_job_id() == f"local-{os.getpid()}"

    def test_explicit_job_id_wins(self, monkeypatch):
        monkeypatch.setenv("SLURM_JOB_ID", "201551")
        reporter = ProgressReporter(job_id="custom-1")
        assert reporter.job_id == "custom-1"


class TestStateDir:
    def test_env_override(self, tmp_path, monkeypatch):
        monkeypatch.setenv("SLURMBAR_STATE_DIR", str(tmp_path / "custom"))
        assert default_state_dir() == str(tmp_path / "custom")

    def test_xdg_state_home(self, tmp_path, monkeypatch):
        monkeypatch.delenv("SLURMBAR_STATE_DIR", raising=False)
        monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
        assert default_state_dir() == str(tmp_path / "slurmbar" / "jobs")

    def test_documented_default(self, monkeypatch):
        monkeypatch.delenv("SLURMBAR_STATE_DIR", raising=False)
        monkeypatch.delenv("XDG_STATE_HOME", raising=False)
        assert default_state_dir().endswith(os.path.join(".local", "state", "slurmbar", "jobs"))

    def test_one_directory_per_job(self, isolated_state_dir):
        a = ProgressReporter(job_id="1001")
        b = ProgressReporter(job_id="1002")
        assert Path(a.status_path) == isolated_state_dir / "1001" / "status.json"
        assert Path(b.status_path) == isolated_state_dir / "1002" / "status.json"
        assert Path(a.status_path).exists() and Path(b.status_path).exists()


# ---------------------------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------------------------


class TestWriting:
    def test_initial_write_records_a_running_job(self):
        reporter = ProgressReporter(kind="training")
        status = read_status(reporter)
        assert status["schema_version"] == 1
        assert status["kind"] == "training"
        assert status["completion"] == "running"
        assert status["pid"] == os.getpid()
        assert status["hostname"]
        assert status["started_at"].endswith("Z")
        assert status["updated_at"].endswith("Z")
        assert status["current"] is None

    def test_update_records_progress_and_metrics(self):
        reporter = ProgressReporter(kind="training", min_interval_seconds=0)
        reporter.update(current=375, total=1000, unit="epoch", phase="train",
                        metrics={"loss": 0.059045, "learning_rate": 3.4e-05})
        status = read_status(reporter)
        assert status["current"] == 375
        assert status["total"] == 1000
        assert status["unit"] == "epoch"
        assert status["phase"] == "train"
        assert status["metrics"]["loss"] == 0.059045

    def test_metrics_accumulate_across_updates(self):
        reporter = ProgressReporter(min_interval_seconds=0)
        reporter.update(current=1, metrics={"loss": 1.0})
        reporter.update(current=2, metrics={"accuracy": 0.5})
        status = read_status(reporter)
        assert status["metrics"] == {"loss": 1.0, "accuracy": 0.5}

    def test_unknown_total_stays_null(self):
        reporter = ProgressReporter(kind="download", min_interval_seconds=0)
        reporter.update(current=4820, unit="file")
        status = read_status(reporter)
        assert status["total"] is None
        assert status["current"] == 4820

    def test_advance_increments(self):
        reporter = ProgressReporter(min_interval_seconds=0)
        reporter.update(current=0, total=10)
        reporter.advance()
        reporter.advance(3)
        assert read_status(reporter)["current"] == 4

    def test_complete_marks_finished_and_fills_the_counter(self):
        reporter = ProgressReporter(min_interval_seconds=0)
        reporter.update(current=999, total=1000)
        reporter.complete(message="Training finished")
        status = read_status(reporter)
        assert status["completion"] == "completed"
        assert status["current"] == 1000
        assert status["message"] == "Training finished"

    def test_fail_records_an_error_summary(self):
        reporter = ProgressReporter(min_interval_seconds=0)
        reporter.update(current=812, total=1000)
        reporter.fail(error="RuntimeError: CUDA out of memory")
        status = read_status(reporter)
        assert status["completion"] == "failed"
        assert status["error"] == "RuntimeError: CUDA out of memory"
        assert status["current"] == 812  # progress at the moment of failure is preserved

    def test_nan_metrics_survive_as_strings(self):
        reporter = ProgressReporter(min_interval_seconds=0)
        reporter.update(current=1, metrics={"loss": float("nan"), "grad": float("inf")})
        status = read_status(reporter)
        assert status["metrics"]["loss"] == "nan"
        assert status["metrics"]["grad"] == "inf"

    def test_non_numeric_metric_values_are_stringified_not_dropped(self):
        reporter = ProgressReporter(min_interval_seconds=0)
        reporter.update(current=1, metrics={"checkpoint": Path("/tmp/ckpt.pt"), "ok": True})
        status = read_status(reporter)
        assert status["metrics"]["checkpoint"] == "/tmp/ckpt.pt"
        assert status["metrics"]["ok"] is True

    def test_arbitrary_workload_kinds(self):
        for kind, unit in [
            ("preprocessing", "file"),
            ("simulation", "timestep"),
            ("sweep", "trial"),
            ("download", "byte"),
            ("generic", "item"),
        ]:
            reporter = ProgressReporter(kind=kind, job_id=f"job-{kind}", min_interval_seconds=0)
            reporter.update(current=5, total=10, unit=unit)
            status = read_status(reporter)
            assert status["kind"] == kind
            assert status["unit"] == unit


# ---------------------------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------------------------


class TestRateLimiting:
    def test_rapid_updates_are_dropped(self):
        reporter = ProgressReporter(min_interval_seconds=60)
        written = [reporter.update(current=i, total=100) for i in range(50)]
        assert not any(written)  # the constructor already wrote once

    def test_in_memory_state_stays_current_even_when_writes_are_skipped(self):
        reporter = ProgressReporter(min_interval_seconds=60)
        for i in range(50):
            reporter.update(current=i, total=100)
        assert reporter.snapshot()["current"] == 49
        reporter.flush()
        assert read_status(reporter)["current"] == 49

    def test_interval_zero_writes_every_time(self):
        reporter = ProgressReporter(min_interval_seconds=0)
        assert all(reporter.update(current=i, total=10) for i in range(5))

    def test_force_bypasses_the_limiter(self):
        reporter = ProgressReporter(min_interval_seconds=3600)
        assert reporter.update(current=1, total=10) is False
        assert reporter.update(current=2, total=10, force=True) is True
        assert read_status(reporter)["current"] == 2

    def test_phase_change_always_forces_a_write(self):
        reporter = ProgressReporter(min_interval_seconds=3600, phase="train")
        assert reporter.update(current=1, phase="train") is False
        # The end of a phase is exactly the moment a user wants to see.
        assert reporter.update(current=2, phase="validate") is True
        assert read_status(reporter)["phase"] == "validate"

    def test_completion_and_failure_always_write(self):
        reporter = ProgressReporter(min_interval_seconds=3600)
        reporter.update(current=1)
        assert reporter.complete() is True

        other = ProgressReporter(job_id="other", min_interval_seconds=3600)
        other.update(current=1)
        assert other.fail(error="boom") is True

    def test_message_is_forced_by_default(self):
        reporter = ProgressReporter(min_interval_seconds=3600)
        assert reporter.message("checkpoint saved") is True
        assert read_status(reporter)["message"] == "checkpoint saved"

    def test_default_interval_is_about_five_seconds(self):
        from slurmbar_progress import DEFAULT_MIN_INTERVAL_SECONDS

        assert DEFAULT_MIN_INTERVAL_SECONDS == pytest.approx(5.0)


# ---------------------------------------------------------------------------------------------
# Atomicity and durability
# ---------------------------------------------------------------------------------------------


class TestAtomicWrites:
    def test_no_temporary_files_are_left_behind(self):
        reporter = ProgressReporter(min_interval_seconds=0)
        for i in range(20):
            reporter.update(current=i, total=20)
        directory = Path(reporter.status_path).parent
        assert [p.name for p in directory.iterdir()] == ["status.json"]

    def test_a_reader_never_sees_a_partial_document(self):
        # os.replace is atomic within a directory, so every read is of a complete file.
        reporter = ProgressReporter(min_interval_seconds=0)
        for i in range(200):
            reporter.update(current=i, total=200, metrics={"loss": 1.0 / (i + 1)})
            payload = json.loads(Path(reporter.status_path).read_text())
            assert payload["current"] == i

    def test_existing_file_is_replaced_not_appended(self):
        reporter = ProgressReporter(min_interval_seconds=0)
        reporter.update(current=1, total=2)
        reporter.update(current=2, total=2)
        text = Path(reporter.status_path).read_text()
        assert text.count('"schema_version"') == 1

    def test_fsync_can_be_disabled(self):
        reporter = ProgressReporter(min_interval_seconds=0, fsync=False)
        reporter.update(current=1, total=2)
        assert read_status(reporter)["current"] == 1


# ---------------------------------------------------------------------------------------------
# Never break the workload
# ---------------------------------------------------------------------------------------------


class TestFailureIsolation:
    def test_unwritable_state_dir_does_not_raise(self, tmp_path, capsys):
        blocked = tmp_path / "blocked"
        blocked.write_text("this is a file, not a directory")
        reporter = ProgressReporter(state_dir=str(blocked), job_id="1", min_interval_seconds=0)
        # Constructing already failed internally; every subsequent call must stay quiet.
        assert reporter.update(current=1, total=2) is False
        assert reporter.complete() is False
        assert reporter.fail(error="x") is False
        assert "slurmbar_progress" in capsys.readouterr().err

    def test_repeated_failures_disable_reporting_rather_than_spamming(self, tmp_path, capsys):
        blocked = tmp_path / "blocked"
        blocked.write_text("file")
        reporter = ProgressReporter(state_dir=str(blocked), job_id="1", min_interval_seconds=0)
        for i in range(30):
            reporter.update(current=i)
        assert reporter._disabled is True

    def test_bad_metric_values_do_not_raise(self):
        class Explodes:
            def __str__(self):
                raise RuntimeError("nope")

        reporter = ProgressReporter(min_interval_seconds=0)
        assert reporter.update(current=1, metrics={"bad": Explodes()}) is False
        # The workload continues; the previous good state is still on disk.
        assert read_status(reporter)["schema_version"] == 1

    def test_directory_removed_mid_run_is_survivable(self, isolated_state_dir):
        import shutil

        reporter = ProgressReporter(min_interval_seconds=0)
        shutil.rmtree(isolated_state_dir)
        assert reporter.update(current=1, total=2) is True  # recreated on demand


# ---------------------------------------------------------------------------------------------
# Context manager
# ---------------------------------------------------------------------------------------------


class TestContextManager:
    def test_normal_exit_marks_completed(self):
        with ProgressReporter(job_id="ctx-ok", min_interval_seconds=0) as reporter:
            reporter.update(current=10, total=10)
        assert read_status(reporter)["completion"] == "completed"

    def test_exception_marks_failed_and_re_raises(self):
        reporter = None
        with pytest.raises(ValueError):
            with ProgressReporter(job_id="ctx-fail", min_interval_seconds=0) as r:
                reporter = r
                r.update(current=3, total=10)
                raise ValueError("training diverged")
        status = read_status(reporter)
        assert status["completion"] == "failed"
        assert "ValueError: training diverged" in status["error"]
        assert status["current"] == 3
