from __future__ import annotations

import json

import pytest

from conftest import read_fixture
from slurmbar_agent.protocol import WarningCollector
from slurmbar_agent.runner import FakeRunner
from slurmbar_agent.squeue import (
    collect,
    expand_node_list,
    parse_squeue_json,
    parse_squeue_text,
)


@pytest.fixture
def warnings() -> WarningCollector:
    return WarningCollector()


# ---------------------------------------------------------------------------------------------
# JSON path
# ---------------------------------------------------------------------------------------------


class TestSqueueJson2311:
    @pytest.fixture
    def jobs(self, warnings):
        return parse_squeue_json(read_fixture("squeue", "squeue-json-2311.json"), warnings)

    def test_all_records_parsed(self, jobs, warnings):
        assert len(jobs) == 3
        assert len(warnings) == 0

    def test_running_job_core_fields(self, jobs):
        job = jobs[0]
        assert job["job_id"] == "201551"
        assert job["name"] == "example-training"
        assert job["state"] == "RUNNING"
        assert job["state_raw"] == "RUNNING"
        assert job["partition"] == "gpu"
        assert job["user"] == "exampleuser"
        assert job["cpus"] == 32
        assert job["gpus"] == 1
        assert job["nodes"] == ["example-gpu-017"]
        assert job["time_limit_seconds"] == 1440 * 60
        assert job["stdout_path"] == "/home/exampleuser/slurmbar-demo/logs/slurm-201551.out"

    def test_running_job_end_time_is_not_the_projected_end(self, jobs):
        # squeue reports a *projected* end for running jobs; exposing it as end_time would
        # make the UI claim a job already finished.
        assert jobs[0]["end_time"] is None
        assert jobs[0]["elapsed_seconds"] is not None and jobs[0]["elapsed_seconds"] > 0

    def test_memory_request_is_labelled_per_node(self, jobs):
        resources = jobs[0]["resources"]
        assert resources["memory_limit_bytes"] == 262144 * 1024 * 1024
        assert resources["memory_limit_semantics"] == "requested_per_node"
        # squeue knows nothing about actual usage.
        assert resources["memory_used_bytes"] is None
        assert resources["memory_semantics"] == "unavailable"

    def test_array_task_identity(self, jobs):
        job = jobs[1]
        assert job["job_id"] == "201560_7"
        assert job["array_job_id"] == "201560"
        assert job["array_task_id"] == "7"
        assert job["state"] == "PENDING"
        assert job["reason"] == "Resources"
        assert job["start_time"] is None

    def test_pending_memory_per_cpu_semantics(self, jobs):
        assert jobs[1]["resources"]["memory_limit_semantics"] == "requested_per_cpu"

    def test_unlimited_time_limit_is_null_not_zero(self, jobs):
        assert jobs[2]["time_limit_seconds"] is None

    def test_compact_node_list_is_expanded(self, jobs):
        assert jobs[2]["nodes"] == ["cpu-004", "cpu-005"]

    def test_no_gpu_reported_stays_null(self, jobs):
        assert jobs[2]["gpus"] is None


class TestSqueueJsonOlderSlurm:
    @pytest.fixture
    def jobs(self, warnings):
        return parse_squeue_json(read_fixture("squeue", "squeue-json-2005.json"), warnings)

    def test_plain_scalars_are_accepted(self, jobs):
        assert len(jobs) == 2
        assert jobs[0]["job_id"] == "88120"
        assert jobs[0]["cpus"] == 4
        assert jobs[0]["time_limit_seconds"] == 720 * 60

    def test_job_state_as_plain_string(self, jobs):
        assert jobs[0]["state"] == "RUNNING"

    def test_pipe_in_job_name_survives_json(self, jobs):
        assert jobs[0]["name"] == "example-run|alpha"

    def test_null_nodes_becomes_empty_list(self, jobs):
        assert jobs[1]["nodes"] == []


class TestSqueueJsonFailures:
    def test_malformed_json_raises_value_error(self, warnings):
        with pytest.raises(ValueError):
            parse_squeue_json("{not json", warnings)

    def test_missing_jobs_array_raises(self, warnings):
        with pytest.raises(ValueError):
            parse_squeue_json(json.dumps({"meta": {}}), warnings)

    def test_one_bad_record_does_not_lose_the_queue(self, warnings):
        payload = json.dumps(
            {"jobs": [{"job_id": 1, "job_state": "RUNNING", "name": "ok"}, "garbage", 42]}
        )
        jobs = parse_squeue_json(payload, warnings)
        assert [j["job_id"] for j in jobs] == ["1"]


# ---------------------------------------------------------------------------------------------
# Text fallback
# ---------------------------------------------------------------------------------------------


class TestSqueueText:
    @pytest.fixture
    def jobs(self, warnings):
        return parse_squeue_text(read_fixture("squeue", "squeue-text.txt"), warnings)

    def test_all_rows_parsed(self, jobs, warnings):
        assert len(jobs) == 4
        assert len(warnings) == 0

    def test_running_row(self, jobs):
        job = jobs[0]
        assert job["job_id"] == "201551"
        assert job["state"] == "RUNNING"
        assert job["elapsed_seconds"] == 8400
        assert job["time_limit_seconds"] == 86400
        assert job["cpus"] == 32
        assert job["gpus"] == 1
        assert job["nodes"] == ["example-gpu-017"]
        assert job["work_dir"] == "/home/exampleuser/slurmbar-demo/train"

    def test_reason_none_is_not_shown_as_a_reason(self, jobs):
        assert jobs[0]["reason"] is None
        assert jobs[1]["reason"] == "Resources"

    def test_array_task_row(self, jobs):
        job = jobs[1]
        assert job["job_id"] == "201560_7"
        assert job["array_job_id"] == "201560"
        assert job["array_task_id"] == "7"
        assert job["start_time"] is None
        assert job["resources"]["memory_limit_semantics"] == "requested_per_cpu"

    def test_pipe_inside_job_name_is_preserved(self, jobs):
        # The multi-character separator is what makes this safe; a bare '|' would not be.
        assert jobs[2]["name"] == "preprocess|shards"

    def test_unlimited_time_limit(self, jobs):
        assert jobs[2]["time_limit_seconds"] is None

    def test_node_range_expansion(self, jobs):
        assert jobs[2]["nodes"] == ["cpu-004", "cpu-005"]

    def test_completing_state(self, jobs):
        assert jobs[3]["state"] == "COMPLETING"
        assert jobs[3]["gpus"] == 2

    def test_text_fallback_cannot_know_log_paths(self, jobs):
        assert all(job["stdout_path"] is None for job in jobs)


def test_malformed_lines_are_skipped_with_a_warning(warnings):
    jobs = parse_squeue_text(read_fixture("squeue", "squeue-text-malformed.txt"), warnings)
    assert [j["job_id"] for j in jobs] == ["201551", "201560_7"]
    codes = [w.code for w in warnings.items]
    assert "SQUEUE_TEXT_UNPARSABLE" in codes


# ---------------------------------------------------------------------------------------------
# collect() orchestration
# ---------------------------------------------------------------------------------------------


def test_collect_prefers_json_when_available(warnings):
    runner = FakeRunner()
    runner.stub("squeue --json", read_fixture("squeue", "squeue-json-2311.json"))
    jobs = collect(runner, "exampleuser", warnings)
    assert len(jobs) == 3
    assert not any(call[:2] == ["squeue", "--noheader"] for call in runner.calls)


def test_collect_falls_back_to_text_when_json_is_unsupported(warnings):
    runner = FakeRunner()
    runner.stub("squeue --json", "", returncode=1, stderr="squeue: invalid option -- '-json'")
    runner.stub("squeue --noheader", read_fixture("squeue", "squeue-text.txt"))
    jobs = collect(runner, "exampleuser", warnings)
    assert len(jobs) == 4
    assert "SQUEUE_JSON_UNSUPPORTED" in [w.code for w in warnings.items]


def test_collect_reports_missing_slurm_as_an_error_warning(warnings):
    runner = FakeRunner(available=[])
    assert collect(runner, "exampleuser", warnings) == []
    warning = next(w for w in warnings.items if w.code == "SLURM_MISSING")
    assert warning.severity == "error"


def test_collect_reports_timeout_distinctly(warnings):
    runner = FakeRunner()
    runner.stub_timeout("squeue --json")
    runner.stub_timeout("squeue --noheader")
    collect(runner, "exampleuser", warnings)
    assert "COMMAND_TIMEOUT" in [w.code for w in warnings.items]


def test_collect_passes_user_as_a_separate_argv_element(warnings):
    runner = FakeRunner()
    runner.stub("squeue --json", read_fixture("squeue", "squeue-json-2311.json"))
    collect(runner, "exampleuser", warnings)
    assert runner.calls[0] == ["squeue", "--json", "--user", "exampleuser"]


# ---------------------------------------------------------------------------------------------
# Node list expansion
# ---------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("example-gpu-017", ["example-gpu-017"]),
        ("cpu-[004-005]", ["cpu-004", "cpu-005"]),
        ("node[1-3]", ["node1", "node2", "node3"]),
        ("node-[017-019,021]", ["node-017", "node-018", "node-019", "node-021"]),
        ("a-01,b-02", ["a-01", "b-02"]),
        ("", []),
        (None, []),
        ("(null)", []),
    ],
)
def test_expand_node_list(raw, expected):
    assert expand_node_list(raw) == expected


def test_expand_node_list_refuses_absurd_ranges():
    # Better to show the compact form than to synthesize 100k host names.
    assert expand_node_list("n[1-999999]") == ["n[1-999999]"]
