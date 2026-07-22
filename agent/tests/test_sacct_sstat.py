from __future__ import annotations

import pytest

from conftest import read_fixture
from slurmbar_agent import sacct, sstat
from slurmbar_agent.protocol import WarningCollector
from slurmbar_agent.runner import FakeRunner


@pytest.fixture
def warnings() -> WarningCollector:
    return WarningCollector()


# ---------------------------------------------------------------------------------------------
# sacct allocations
# ---------------------------------------------------------------------------------------------


class TestSacctAllocations:
    @pytest.fixture
    def jobs(self, warnings):
        return sacct.parse_sacct_allocations(read_fixture("sacct", "sacct-allocations.txt"), warnings)

    def test_all_rows_parsed(self, jobs, warnings):
        assert len(jobs) == 6
        assert len(warnings) == 0

    def test_completed_job(self, jobs):
        job = jobs[0]
        assert job["job_id"] == "201540"
        assert job["state"] == "COMPLETED"
        assert job["exit_code"] == 0
        assert job["elapsed_seconds"] == 28800
        assert job["time_limit_seconds"] == 1440 * 60  # TimelimitRaw is minutes
        assert job["end_time"] == "2026-07-21T18:05:00Z"
        assert job["source"] == "sacct"
        assert job["gpus"] == 1

    def test_pipe_in_job_name_is_preserved_because_jobname_is_last(self, jobs):
        assert jobs[1]["name"] == "example-failed|with|pipes"
        assert jobs[1]["state"] == "FAILED"
        assert jobs[1]["exit_code"] == 1

    def test_timeout_state_and_signal(self, jobs):
        job = jobs[2]
        assert job["state"] == "TIMEOUT"
        assert job["exit_code"] == 0
        assert job["signal"] == 1

    def test_out_of_memory_is_its_own_state(self, jobs):
        assert jobs[3]["state"] == "OUT_OF_MEMORY"

    def test_cancelled_by_uid_keeps_raw(self, jobs):
        assert jobs[4]["state"] == "CANCELLED"
        assert jobs[4]["state_raw"] == "CANCELLED by 100234"

    def test_reqmem_per_node_suffix_is_labelled(self, jobs):
        assert jobs[2]["resources"]["memory_limit_semantics"] == "requested_per_node"
        assert jobs[2]["resources"]["memory_limit_bytes"] == 64 * 1024**3

    def test_reqmem_without_suffix_is_total(self, jobs):
        assert jobs[0]["resources"]["memory_limit_semantics"] == "requested_total"

    def test_running_job_from_accounting_has_unknown_end_time(self, jobs):
        assert jobs[5]["state"] == "RUNNING"
        assert jobs[5]["end_time"] is None


def test_sacct_skips_step_rows_defensively(warnings):
    payload = "201540.batch|COMPLETED|gpu|u|a|normal|||||||||||\n"
    assert sacct.parse_sacct_allocations(payload, warnings) == []


def test_sacct_short_row_is_skipped_with_a_warning(warnings):
    jobs = sacct.parse_sacct_allocations("201540|COMPLETED|gpu\n", warnings)
    assert jobs == []
    assert "PARTIAL_DATA" in [w.code for w in warnings.items]


# ---------------------------------------------------------------------------------------------
# sacct step memory
# ---------------------------------------------------------------------------------------------


class TestSacctSteps:
    @pytest.fixture
    def peaks(self):
        return sacct.parse_sacct_steps(read_fixture("sacct", "sacct-steps.txt"))

    def test_largest_step_wins(self, peaks):
        assert peaks["201540"]["memory_used_bytes"] == 24117248 * 1024

    def test_gpu_memory_only_when_accounting_reported_it(self, peaks):
        assert peaks["201540"]["gpu_memory_used_bytes"] == 39321 * 1024**2
        assert peaks["201542"]["gpu_memory_used_bytes"] is None

    def test_jobs_without_steps_have_no_memory(self, peaks):
        assert peaks["201548"]["memory_used_bytes"] is None

    def test_applied_memory_is_labelled_per_step_peak(self, warnings):
        jobs = sacct.parse_sacct_allocations(read_fixture("sacct", "sacct-allocations.txt"), warnings)
        sacct._apply_step_memory(jobs, sacct.parse_sacct_steps(read_fixture("sacct", "sacct-steps.txt")))
        completed = jobs[0]
        assert completed["resources"]["memory_used_bytes"] == 24117248 * 1024
        assert completed["resources"]["memory_semantics"] == "peak_rss_per_step"


# ---------------------------------------------------------------------------------------------
# sacct availability
# ---------------------------------------------------------------------------------------------


def test_missing_sacct_is_informational_not_fatal(warnings):
    runner = FakeRunner(available=["squeue"])
    assert sacct.collect_history(runner, "exampleuser", 24, warnings) == []
    warning = next(w for w in warnings.items if w.code == "SACCT_UNAVAILABLE")
    assert warning.severity == "info"


def test_accounting_disabled_is_reported_distinctly(warnings):
    runner = FakeRunner()
    runner.stub("sacct", "", returncode=1, stderr="sacct: error: slurm accounting storage is disabled")
    sacct.collect_history(runner, "exampleuser", 24, warnings)
    assert "ACCOUNTING_DISABLED" in [w.code for w in warnings.items]


def test_other_sacct_failure_is_not_mislabelled_as_disabled_accounting(warnings):
    runner = FakeRunner()
    runner.stub("sacct", "", returncode=1, stderr="sacct: error: Problem talking to the database")
    sacct.collect_history(runner, "exampleuser", 24, warnings)
    codes = [w.code for w in warnings.items]
    assert "SACCT_FAILED" in codes
    assert "ACCOUNTING_DISABLED" not in codes


def test_history_window_is_passed_to_sacct(warnings):
    runner = FakeRunner()
    runner.stub("sacct", "")
    sacct.collect_history(runner, "exampleuser", 6, warnings)
    assert "--starttime=now-6hours" in runner.calls[0]


# ---------------------------------------------------------------------------------------------
# sstat
# ---------------------------------------------------------------------------------------------


class TestSstat:
    @pytest.fixture
    def usage(self):
        return sstat.parse_sstat(read_fixture("sstat", "sstat-running.txt"))

    def test_peak_rss_across_steps(self, usage):
        assert usage["201551"]["memory_used_bytes"] == 118111600 * 1024

    def test_gpu_metrics_are_only_taken_from_accounting_tres(self, usage):
        assert usage["201551"]["gpu_memory_used_bytes"] == 40265 * 1024**2
        assert usage["201551"]["gpu_utilization_percent"] == 87.0
        assert usage["201570"]["gpu_memory_used_bytes"] is None

    def test_apply_marks_semantics_as_peak_rss(self, usage):
        jobs = [
            {"job_id": "201551", "state": "RUNNING", "resources": {
                "memory_used_bytes": None, "memory_semantics": "unavailable",
                "gpu_memory_used_bytes": None, "gpu_utilization_percent": None}},
        ]
        sstat.apply_live_usage(jobs, usage)
        assert jobs[0]["resources"]["memory_semantics"] == "peak_rss"
        assert jobs[0]["resources"]["memory_used_bytes"] == 118111600 * 1024


def test_sstat_batches_all_running_jobs_into_one_call(warnings):
    runner = FakeRunner()
    runner.stub("sstat", read_fixture("sstat", "sstat-running.txt"))
    sstat.collect_live_usage(runner, ["201551", "201570"], warnings)
    assert len(runner.calls) == 1
    assert "--jobs=201551,201570" in runner.calls[0]


def test_sstat_failure_is_informational(warnings):
    runner = FakeRunner()
    runner.stub("sstat", "", returncode=1, stderr="sstat: error: no steps running for job 201551")
    assert sstat.collect_live_usage(runner, ["201551"], warnings) == {}
    warning = next(w for w in warnings.items if w.code == "SSTAT_FAILED")
    assert warning.severity == "info"


def test_missing_sstat_is_reported_once(warnings):
    runner = FakeRunner(available=["squeue"])
    assert sstat.collect_live_usage(runner, ["201551"], warnings) == {}
    assert "SSTAT_UNAVAILABLE" in [w.code for w in warnings.items]


def test_no_running_jobs_makes_no_call(warnings):
    runner = FakeRunner()
    assert sstat.collect_live_usage(runner, [], warnings) == {}
    assert runner.calls == []
