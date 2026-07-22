"""Regression tests for synthetic Slurm 25.11-shaped data.

The fixture preserves protocol structures needed for compatibility tests — nested
`{set,infinite,number}` wrappers, `job_state` as a list, unexpanded filename patterns and TRES
strings — while every identifier, timestamp and resource value is fictional.
"""

from __future__ import annotations

import json

import pytest

from conftest import read_fixture
from slurmbar_agent.protocol import WarningCollector
from slurmbar_agent.runner import FakeRunner
from slurmbar_agent.squeue import parse_squeue_json
from slurmbar_agent.snapshot import build_snapshot

FIXTURE = ("squeue", "squeue-json-2511.json")


@pytest.fixture
def warnings() -> WarningCollector:
    return WarningCollector()


@pytest.fixture
def jobs(warnings):
    return parse_squeue_json(read_fixture(*FIXTURE), warnings)


class TestSlurm2511Shapes:
    """Slurm 25.11 wraps nearly every scalar and reports job_state as a list."""

    def test_all_records_parse(self, jobs, warnings):
        assert len(jobs) == 4
        assert len(warnings) == 0

    def test_wrapped_scalars(self, jobs):
        job = jobs[0]
        assert job["cpus"] == 12
        assert job["node_count"] == 1
        assert job["time_limit_seconds"] == 720 * 60

    def test_job_state_list(self, jobs):
        assert jobs[0]["state"] == "RUNNING"
        assert jobs[0]["state_raw"] == "RUNNING"
        assert jobs[2]["state"] == "PENDING"

    def test_pending_start_time_is_set_true_with_zero(self, jobs):
        # Slurm 25.11 reports {"set": true, "number": 0} rather than set:false for a pending
        # job's start time. Treating 0 as a real epoch would show a 1970 start date.
        pending = jobs[2]
        assert pending["start_time"] is None
        assert pending["state"] == "PENDING"

    def test_pending_reason_preserved(self, jobs):
        assert jobs[2]["reason"] == "Dependency"

    def test_running_job_has_no_projected_end_time(self, jobs):
        assert jobs[0]["end_time"] is None


class TestArrayIdentity:
    """Array tasks must be addressed the way squeue displays them."""

    def test_array_task_uses_parent_underscore_task(self, jobs):
        assert jobs[0]["job_id"] == "500103_0"
        assert jobs[0]["array_job_id"] == "500103"
        assert jobs[0]["array_task_id"] == "0"

    def test_task_zero_is_not_treated_as_absent(self, jobs):
        # array_task_id 0 is falsy; an `if array_task_id:` check would silently turn task 0
        # into a standalone job and break progress matching for it.
        assert jobs[0]["array_task_id"] == "0"

    def test_second_task_shares_the_parent(self, jobs):
        assert jobs[1]["job_id"] == "500103_1"
        assert jobs[1]["array_job_id"] == "500103"

    def test_non_array_job_with_zero_array_job_id(self, jobs):
        assert jobs[2]["job_id"] == "500109"
        assert jobs[2]["array_job_id"] is None
        assert jobs[2]["array_task_id"] is None

    def test_non_array_job_whose_array_job_id_equals_itself(self, jobs):
        # Slurm reports array_job_id == job_id for some non-array jobs; array_task_id being
        # unset is the only reliable discriminator.
        assert jobs[3]["job_id"] == "500112"
        assert jobs[3]["array_task_id"] is None


class TestMemorySemantics:
    """`memory_per_node` is not necessarily an individual job's memory request."""

    def test_memory_comes_from_tres_not_memory_per_node(self, jobs):
        # The synthetic fixture intentionally gives every record the same node-level value while
        # the per-job TRES requests differ. The parser must prefer each job's own request.
        assert jobs[0]["resources"]["memory_limit_bytes"] == 10 * 1024**3
        assert jobs[2]["resources"]["memory_limit_bytes"] == 20 * 1024**3
        assert jobs[3]["resources"]["memory_limit_bytes"] == 30 * 1024**3

    def test_memory_semantics_labelled_as_an_allocation_total(self, jobs):
        # Slurm documents TRES as the aggregate for the whole allocation, so `requested_total`
        # is the honest label even though these jobs happen to be single-node.
        assert jobs[0]["resources"]["memory_limit_semantics"] == "requested_total"

    def test_squeue_reports_no_usage(self, jobs):
        assert jobs[0]["resources"]["memory_used_bytes"] is None
        assert jobs[0]["resources"]["memory_semantics"] == "unavailable"


class TestGPUCount:
    """A numeric suffix in a synthetic GPU model must not become the GPU count."""

    def test_gpu_count_ignores_the_model_number(self, jobs):
        assert jobs[0]["gpus"] == 1

    def test_all_jobs_report_one_gpu(self, jobs):
        assert [j["gpus"] for j in jobs] == [1, 1, 1, 1]


class TestLogPathExpansion:
    """Slurm 25.11 returns the *unexpanded* filename pattern from squeue --json."""

    def test_array_pattern_is_expanded(self, jobs):
        # Raw value: /home/exampleuser/slurmbar-demo/logs/%x-%A_%a.out
        # scontrol shows the expansion, so the app must produce the same path.
        assert jobs[0]["stdout_path"] == (
            "/home/exampleuser/slurmbar-demo/logs/example-array-500103_0.out"
        )
        assert jobs[1]["stdout_path"] == (
            "/home/exampleuser/slurmbar-demo/logs/example-array-500103_1.out"
        )

    def test_job_id_pattern_is_expanded(self, jobs):
        # Raw value: .../%x-%j.out
        assert jobs[2]["stdout_path"] == (
            "/home/exampleuser/slurmbar-demo/logs/example-array-500109.out"
        )

    def test_stderr_is_expanded_too(self, jobs):
        assert "%" not in (jobs[0]["stderr_path"] or "")

    def test_unresolvable_pattern_yields_no_path_rather_than_a_broken_one(self, jobs):
        # A pending array job has no task id yet, so %a cannot be resolved. Reporting
        # ".../example-array-500112_%a.out" would just fail to open later.
        assert jobs[3]["stdout_path"] is None

    def test_no_percent_tokens_survive_anywhere(self, jobs):
        for job in jobs:
            for key in ("stdout_path", "stderr_path"):
                value = job.get(key)
                if value:
                    assert "%" not in value, f"{key} still contains a pattern: {value}"


class TestExitCodeShape:
    """Slurm 25.11 nests the signal id inside its own {set,number} wrapper."""

    def test_unset_signal_is_none_not_zero(self, jobs):
        # {"signal": {"id": {"set": false, "number": 0}}} means "no signal", not "signal 0".
        assert jobs[0]["signal"] is None

    def test_exit_code_wrapper_still_decodes_for_a_finished_job(self):
        # The running jobs in the fixture correctly report no exit status, so the nested
        # Slurm 25.11 wrapper is exercised directly here.
        from slurmbar_agent.timeutil import parse_exit_code

        payload = {
            "status": ["SUCCESS"],
            "return_code": {"set": True, "infinite": False, "number": 0},
            "signal": {"id": {"set": False, "infinite": False, "number": 0}, "name": ""},
        }
        assert parse_exit_code(payload) == (0, None)

        failed = {
            "status": ["FAILED"],
            "return_code": {"set": True, "infinite": False, "number": 1},
            "signal": {"id": {"set": True, "infinite": False, "number": 9}, "name": "SIGKILL"},
        }
        assert parse_exit_code(failed) == (1, 9)


class TestDefaultUserScope:
    """A personal menu bar app must default to the invoking user's own jobs."""

    def test_snapshot_defaults_to_the_current_user(self, tmp_path, monkeypatch):
        # Without a default user filter the agent can return other users' jobs and attempt to read
        # log paths that are outside this personal menu bar app's scope.
        monkeypatch.setenv("USER", "exampleuser")
        runner = FakeRunner()
        runner.stub("squeue --json", read_fixture(*FIXTURE))
        runner.stub("sacct", "")
        runner.stub("sstat", "")
        runner.stub("scontrol show config", "ClusterName = examplecluster\n")

        build_snapshot(runner, user=None, progress_dir=str(tmp_path))

        squeue_call = next(c for c in runner.calls if c[0] == "squeue")
        assert "--user" in squeue_call, "squeue must be filtered to one user by default"
        assert squeue_call[squeue_call.index("--user") + 1] == "exampleuser"

    def test_explicit_all_users_opt_out(self, tmp_path, monkeypatch):
        monkeypatch.setenv("USER", "exampleuser")
        runner = FakeRunner()
        runner.stub("squeue --json", read_fixture(*FIXTURE))
        runner.stub("sacct", "")
        runner.stub("sstat", "")
        runner.stub("scontrol show config", "")

        build_snapshot(runner, user=None, all_users=True, progress_dir=str(tmp_path))

        squeue_call = next(c for c in runner.calls if c[0] == "squeue")
        assert "--user" not in squeue_call

    def test_explicit_user_still_wins(self, tmp_path, monkeypatch):
        monkeypatch.setenv("USER", "exampleuser")
        runner = FakeRunner()
        runner.stub("squeue --json", read_fixture(*FIXTURE))
        runner.stub("sacct", "")
        runner.stub("sstat", "")
        runner.stub("scontrol show config", "")

        build_snapshot(runner, user="someoneelse", progress_dir=str(tmp_path))

        squeue_call = next(c for c in runner.calls if c[0] == "squeue")
        assert squeue_call[squeue_call.index("--user") + 1] == "someoneelse"


class TestEndToEndAgainstSyntheticShapes:
    def test_snapshot_builds_and_serializes(self, tmp_path, monkeypatch):
        monkeypatch.setenv("USER", "exampleuser")
        runner = FakeRunner()
        runner.stub("squeue --json", read_fixture(*FIXTURE))
        runner.stub("sacct", "")
        runner.stub("sstat", "")
        runner.stub(
            "scontrol show config",
            "ClusterName             = examplecluster\nSLURM_VERSION           = 25.11.0\n",
        )
        snapshot = build_snapshot(runner, progress_dir=str(tmp_path))

        assert snapshot["cluster"]["slurm_version"] == "25.11.0"
        assert snapshot["summary"]["running"] == 2
        assert snapshot["summary"]["pending"] == 2
        json.dumps(snapshot)


class TestActiveJobsHaveNoExitStatus:
    """Slurm reports exit_code 0 for jobs that have not exited yet."""

    def test_running_job_reports_no_exit_code(self, jobs):
        assert jobs[0]["state"] == "RUNNING"
        assert jobs[0]["exit_code"] is None
        assert jobs[0]["signal"] is None

    def test_pending_job_reports_no_exit_code(self, jobs):
        assert jobs[2]["state"] == "PENDING"
        assert jobs[2]["exit_code"] is None

    def test_accounting_does_not_resurrect_an_exit_code_for_a_running_job(self, tmp_path, monkeypatch):
        # sacct also reports 0:0 for running jobs; the merge must not fold that in.
        monkeypatch.setenv("USER", "exampleuser")
        runner = FakeRunner()
        runner.stub("squeue --json", read_fixture(*FIXTURE))
        runner.stub(
            "sacct --noheader --parsable2 --allocations",
            "500103_0|RUNNING|gpu|exampleuser|acct|normal|2026-07-22T12:59:45|"
            "2026-07-22T12:59:45|Unknown|5594|720|0:0|1|12|10G|cpu=12,mem=10G|example-node-a|example-array\n",
        )
        runner.stub("sstat", "")
        runner.stub("scontrol show config", "")
        snapshot = build_snapshot(runner, progress_dir=str(tmp_path))
        job = next(j for j in snapshot["jobs"] if j["job_id"] == "500103_0")
        assert job["state"] == "RUNNING"
        assert job["exit_code"] is None
        assert job["end_time"] is None


class TestSstatArrayAttribution:
    """`sstat` answers array queries using the underlying job ids, not array notation.

    Asking `sstat --jobs=500103_0,500103_1` returns rows keyed `500100.batch`, `500106.batch`
    — the tasks' own Slurm job ids. Matching only on the display id ("500103_0") therefore
    missed every task and fell back to the array parent, giving every task in an array the
    same memory figure.
    """

    def test_each_array_task_gets_its_own_memory(self, jobs):
        from slurmbar_agent import sstat

        usage = sstat.parse_sstat(read_fixture("sstat", "sstat-array-tasks.txt"))
        sstat.apply_live_usage(jobs, usage)

        first = jobs[0]["resources"]["memory_used_bytes"]
        second = jobs[1]["resources"]["memory_used_bytes"]
        assert first == 100000 * 1024
        assert second == 200000 * 1024
        assert first != second, "array tasks must not all report the parent's memory"

    def test_raw_slurm_job_id_is_carried_for_matching(self, jobs):
        # 500103_0 is the display id; 500100 is the id Slurm uses internally and that sstat
        # answers with.
        assert jobs[0]["slurm_job_id"] == "500100"
        assert jobs[1]["slurm_job_id"] == "500106"
