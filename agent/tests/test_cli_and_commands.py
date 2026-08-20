"""CLI surface, doctor, job/logs commands.

`cancel` is deliberately never executed here. Only its argument guards are tested; the code
path that would invoke `scancel` is exercised solely through a fake runner that records the
argv without running anything.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from conftest import read_fixture
from slurmbar_agent import commands, doctor as doctor_mod, gpu as gpu_mod
from slurmbar_agent.cli import build_parser, main
from slurmbar_agent.errors import InvalidArgument, NotFound
from slurmbar_agent.runner import FakeRunner
from slurmbar_agent.scontrol import expand_filename_pattern, log_paths, parse_scontrol


# ---------------------------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------------------------


def healthy_runner() -> FakeRunner:
    runner = FakeRunner()
    runner.stub("squeue --json", read_fixture("squeue", "squeue-json-2311.json"))
    runner.stub("squeue --noheader", "201551\n201570\n")
    runner.stub("sacct", "201540\n")
    runner.stub("sinfo --version", "slurm 23.11.7\n")
    return runner


def checks_by_id(report):
    return {check["id"]: check for check in report["checks"]}


class TestDoctor:
    def test_healthy_cluster_reports_ok(self, tmp_path: Path):
        report = doctor_mod.run_doctor(healthy_runner(), progress_dir=str(tmp_path))
        assert report["ok"] is True
        assert report["schema_version"] == 1
        checks = checks_by_id(report)
        assert checks["python"]["status"] == "ok"
        assert checks["slurm_commands"]["status"] == "ok"
        assert checks["slurm_version"]["value"] == "slurm 23.11.7"
        assert checks["squeue"]["status"] == "ok"
        assert checks["squeue_json"]["status"] == "ok"
        assert checks["sacct"]["status"] == "ok"
        assert checks["progress_dir"]["status"] == "ok"

    def test_missing_squeue_is_a_hard_failure_with_an_actionable_hint(self, tmp_path: Path):
        runner = FakeRunner(available=[])
        report = doctor_mod.run_doctor(runner, progress_dir=str(tmp_path))
        assert report["ok"] is False
        check = checks_by_id(report)["slurm_commands"]
        assert check["status"] == "fail"
        assert "PATH" in check["detail"]

    def test_squeue_json_unsupported_is_a_warning_not_a_failure(self, tmp_path: Path):
        runner = healthy_runner()
        runner.stub("squeue --json", "", returncode=1, stderr="unrecognized option '--json'")
        report = doctor_mod.run_doctor(runner, progress_dir=str(tmp_path))
        assert report["ok"] is True
        assert checks_by_id(report)["squeue_json"]["status"] == "warn"

    def test_accounting_unavailable_is_a_warning(self, tmp_path: Path):
        runner = healthy_runner()
        runner.stub("sacct", "", returncode=1, stderr="sacct: error: accounting disabled")
        report = doctor_mod.run_doctor(runner, progress_dir=str(tmp_path))
        assert report["ok"] is True
        assert checks_by_id(report)["sacct"]["status"] == "warn"

    def test_absent_progress_dir_is_explained_not_failed(self, tmp_path: Path):
        report = doctor_mod.run_doctor(healthy_runner(), progress_dir=str(tmp_path / "not-yet"))
        check = checks_by_id(report)["progress_dir"]
        assert check["status"] == "warn"
        assert "slurmbar_progress" in check["detail"]

    def test_progress_dir_with_jobs_counts_them(self, tmp_path: Path):
        (tmp_path / "201551").mkdir()
        report = doctor_mod.run_doctor(healthy_runner(), progress_dir=str(tmp_path))
        assert checks_by_id(report)["progress_dir"]["status"] == "ok"
        assert "1 job director" in checks_by_id(report)["progress_dir"]["detail"]


# ---------------------------------------------------------------------------------------------
# scontrol parsing
# ---------------------------------------------------------------------------------------------


SCONTROL_LINE = (
    "JobId=201551 JobName=example training UserId=exampleuser(100234) GroupId=exampleaccount(2000) "
    "Priority=4294 Nice=0 Account=exampleaccount QOS=normal JobState=RUNNING Reason=None Dependency=(null) "
    "NodeList=example-gpu-017 NumNodes=1 NumCPUs=32 "
    "WorkDir=/home/exampleuser/slurmbar-demo/train StdErr=/home/exampleuser/slurmbar-demo/logs/slurm-201551.err "
    "StdIn=/dev/null StdOut=/home/exampleuser/slurmbar-demo/logs/slurm-201551.out Power="
)


class TestScontrol:
    def test_key_value_parsing_tolerates_spaces_in_values(self):
        fields = parse_scontrol(SCONTROL_LINE)
        assert fields["JobId"] == "201551"
        assert fields["JobName"] == "example training"
        assert fields["StdOut"] == "/home/exampleuser/slurmbar-demo/logs/slurm-201551.out"

    def test_log_paths_extracted(self):
        paths = log_paths(parse_scontrol(SCONTROL_LINE))
        assert paths["stdout_path"].endswith("slurm-201551.out")
        assert paths["stderr_path"].endswith("slurm-201551.err")
        assert paths["work_dir"] == "/home/exampleuser/slurmbar-demo/train"

    @pytest.mark.parametrize(
        "pattern,expected",
        [
            ("/logs/slurm-%j.out", "/logs/slurm-201551.out"),
            ("/logs/%x-%j.out", "/logs/train-201551.out"),
            ("/logs/%A_%a.out", "/logs/201551_3.out"),
            ("/logs/100%%.out", "/logs/100%.out"),
        ],
    )
    def test_filename_pattern_expansion(self, pattern, expected):
        context = {"j": "201551", "A": "201551", "a": "3", "x": "train"}
        assert expand_filename_pattern(pattern, context) == expected

    def test_partially_resolvable_pattern_yields_no_path(self):
        # A path that still contains an unresolved token cannot be opened, so reporting it
        # would only turn into a confusing "file not found" later. "Unknown" is the honest
        # answer. (Changed from returning "/logs/%N-1.out" after observing Slurm 25.11 return
        # unexpanded patterns for pending array jobs.)
        assert expand_filename_pattern("/logs/%N-%j.out", {"j": "1"}) is None

    def test_fully_resolvable_pattern_is_expanded(self):
        assert expand_filename_pattern("/logs/%N-%j.out", {"j": "1", "N": "node01"}) == (
            "/logs/node01-1.out"
        )


# ---------------------------------------------------------------------------------------------
# logs
# ---------------------------------------------------------------------------------------------


class TestLogs:
    def test_reads_a_bounded_tail_from_a_known_path(self, tmp_path: Path):
        log = tmp_path / "job.out"
        log.write_text("\n".join(f"line {i}" for i in range(500)) + "\n")
        payload = commands.read_logs(FakeRunner(), "201551", lines=10, path_override=str(log))
        assert payload["schema_version"] == 1
        assert len(payload["lines"]) == 10
        assert payload["lines"][-1] == "line 499"
        assert payload["truncated"] is True
        assert payload["stream"] == "stdout"

    def test_line_count_is_capped(self, tmp_path: Path):
        log = tmp_path / "job.out"
        log.write_text("a\n")
        payload = commands.read_logs(FakeRunner(), "201551", lines=10**9, path_override=str(log))
        assert len(payload["lines"]) <= commands.MAX_LOG_LINES

    def test_resolves_the_path_through_scontrol_when_not_given(self, tmp_path: Path):
        log = tmp_path / "resolved.out"
        log.write_text("hello\n")
        runner = FakeRunner()
        runner.stub("scontrol --oneliner show job 201551", f"JobId=201551 StdOut={log} StdErr={log}")
        payload = commands.read_logs(runner, "201551")
        assert payload["path"] == str(log)
        assert payload["lines"] == ["hello"]

    def test_unknown_path_is_a_structured_warning_not_an_exception(self):
        runner = FakeRunner(available=[])
        payload = commands.read_logs(runner, "201551")
        assert payload["lines"] == []
        assert payload["warnings"][0]["code"] == "LOG_PATH_UNKNOWN"

    def test_missing_file_is_reported(self, tmp_path: Path):
        payload = commands.read_logs(
            FakeRunner(), "201551", path_override=str(tmp_path / "gone.out")
        )
        assert payload["lines"] == []
        assert payload["warnings"]

    def test_invalid_job_id_is_refused(self):
        with pytest.raises(InvalidArgument):
            commands.read_logs(FakeRunner(), "201551; cat /etc/passwd")

    def test_invalid_stream_is_refused(self, tmp_path: Path):
        with pytest.raises(InvalidArgument):
            commands.read_logs(FakeRunner(), "201551", stream="../../etc/passwd")


# ---------------------------------------------------------------------------------------------
# job detail
# ---------------------------------------------------------------------------------------------


class TestJobDetail:
    def test_returns_the_queued_job_with_resolved_log_paths(self, tmp_path: Path):
        runner = FakeRunner()
        runner.stub("squeue --noheader --jobs 201551", read_fixture("squeue", "squeue-text.txt"))
        runner.stub("scontrol --oneliner show job 201551", SCONTROL_LINE)
        runner.stub("sstat", read_fixture("sstat", "sstat-running.txt"))
        payload = commands.job_detail(runner, "201551", progress_dir=str(tmp_path))
        job = payload["job"]
        assert job["job_id"] == "201551"
        assert job["stdout_path"].endswith("slurm-201551.out")
        assert job["resources"]["memory_semantics"] == "peak_rss"

    def test_falls_back_to_accounting_for_a_finished_job(self, tmp_path: Path):
        runner = FakeRunner()
        runner.stub("squeue --noheader --jobs 201540", "")
        runner.stub(
            "sacct --noheader --parsable2 --allocations --jobs 201540",
            read_fixture("sacct", "sacct-allocations.txt"),
        )
        runner.stub(
            "sacct --noheader --parsable2 --jobs 201540", read_fixture("sacct", "sacct-steps.txt")
        )
        payload = commands.job_detail(runner, "201540", progress_dir=str(tmp_path))
        assert payload["job"]["state"] == "COMPLETED"
        assert payload["job"]["resources"]["memory_semantics"] == "peak_rss_per_step"

    def test_vanished_job_raises_not_found(self, tmp_path: Path):
        runner = FakeRunner()
        runner.stub("squeue", "")
        runner.stub("sacct", "")
        with pytest.raises(NotFound):
            commands.job_detail(runner, "999999", progress_dir=str(tmp_path))

    def test_invalid_job_id_is_refused_before_any_command_runs(self, tmp_path: Path):
        runner = FakeRunner()
        with pytest.raises(InvalidArgument):
            commands.job_detail(runner, "$(id)", progress_dir=str(tmp_path))
        assert runner.calls == []


# ---------------------------------------------------------------------------------------------
# gpu
# ---------------------------------------------------------------------------------------------


class TestGPUStatus:
    def test_parses_multiple_devices_and_preserves_argv_boundaries(self):
        runner = FakeRunner()
        runner.stub("squeue --noheader --jobs 282940_0", "282940_0|1|gres/gpu:2\n")
        runner.stub(
            "srun --jobid=282940_0",
            "gpu-01|0, NVIDIA A100-SXM4-40GB, 97, 25185, 40960, 260.25\n"
            "gpu-01|1, NVIDIA A100-SXM4-40GB, 4, 1024, 40960, [Not Supported]\n",
        )
        payload = gpu_mod.collect_gpu_status(runner, ["282940_0"])

        assert payload["jobs"][0]["ok"] is True
        assert payload["jobs"][0]["gpus"][0]["utilization_percent"] == 97
        assert payload["jobs"][0]["gpus"][0]["node"] == "gpu-01"
        assert payload["jobs"][0]["gpus"][1]["power_draw_watts"] is None
        assert runner.calls[1][:6] == [
            "srun", "--jobid=282940_0", "--overlap", "--nodes=1", "--ntasks=1",
            "--ntasks-per-node=1",
        ]

    def test_one_failed_job_does_not_discard_other_jobs(self):
        runner = FakeRunner()
        runner.stub("squeue --noheader --jobs 1,2", "1|1|gres/gpu:1\n2|1|gres/gpu:1\n")
        runner.stub("srun --jobid=1", "gpu-01|0, NVIDIA H100, 90, 40000, 81920, 500\n")
        runner.stub("srun --jobid=2", "", returncode=1, stderr="job step creation disabled")
        payload = gpu_mod.collect_gpu_status(runner, ["1", "2"])

        assert [job["ok"] for job in payload["jobs"]] == [True, False]
        assert "job step creation disabled" in payload["jobs"][1]["message"]

    def test_invalid_job_id_is_refused_before_srun(self):
        runner = FakeRunner()
        with pytest.raises(InvalidArgument):
            gpu_mod.collect_gpu_status(runner, ["1", "$(id)"])
        assert runner.calls == []

    def test_queries_every_node_and_keeps_node_identity(self):
        runner = FakeRunner()
        runner.stub("squeue --noheader --jobs 42", "42|2|gres/gpu:2\n")
        runner.stub(
            "srun --jobid=42",
            "gpu-01|0, NVIDIA H200, 10, 100, 1000, 200\n"
            "gpu-01|1, NVIDIA H200, 20, 200, 1000, 210\n"
            "gpu-02|0, NVIDIA H200, 30, 300, 1000, 220\n"
            "gpu-02|1, NVIDIA H200, 40, 400, 1000, 230\n",
        )

        job = gpu_mod.collect_gpu_status(runner, ["42"])["jobs"][0]
        assert job["ok"] is True
        assert job["message"] is None
        assert {gpu["node"] for gpu in job["gpus"]} == {"gpu-01", "gpu-02"}
        srun = runner.calls[1]
        assert "--nodes=2" in srun
        assert "--ntasks=2" in srun

    def test_hides_devices_when_nvidia_smi_exposes_more_than_allocated(self):
        runner = FakeRunner()
        runner.stub("squeue --noheader --jobs 42", "42|1|gres/gpu:1\n")
        runner.stub(
            "srun --jobid=42",
            "gpu-01|0, NVIDIA H200, 10, 100, 1000, 200\n"
            "gpu-01|1, NVIDIA H200, 20, 200, 1000, 210\n",
        )

        job = gpu_mod.collect_gpu_status(runner, ["42"])["jobs"][0]
        assert job["ok"] is False
        assert job["gpus"] == []
        assert "more GPUs than Slurm allocated" in job["message"]

    def test_more_than_the_job_limit_is_rejected_not_silently_truncated(self):
        runner = FakeRunner()
        with pytest.raises(InvalidArgument, match="too many GPU jobs"):
            gpu_mod.collect_gpu_status(runner, [str(i) for i in range(1, 66)])
        assert runner.calls == []


# ---------------------------------------------------------------------------------------------
# cancel  (guards only — scancel is never executed)
# ---------------------------------------------------------------------------------------------


class TestCancelGuards:
    def test_cli_refuses_without_confirm(self, capsys):
        exit_code = main(["cancel", "--job-id", "201551", "--json"])
        assert exit_code == 2
        payload = json.loads(capsys.readouterr().out)
        assert payload["error"]["code"] == "INVALID_ARGUMENT"

    def test_invalid_job_id_never_reaches_scancel(self):
        runner = FakeRunner()
        with pytest.raises(InvalidArgument):
            commands.cancel_job(runner, "201551 || rm -rf ~")
        assert runner.calls == []

    def test_argv_is_built_without_a_shell(self):
        # FakeRunner records argv and runs nothing, so no scancel is ever executed.
        runner = FakeRunner()
        runner.stub("scancel", "", returncode=0)
        result = commands.cancel_job(runner, "201551")
        assert runner.calls == [["scancel", "--verbose", "201551"]]
        assert result["ok"] is True
        assert result["job_id"] == "201551"

    def test_missing_scancel_is_reported_structurally(self):
        runner = FakeRunner(available=["squeue"])
        result = commands.cancel_job(runner, "201551")
        assert result["ok"] is False
        assert "not available" in result["message"]


# ---------------------------------------------------------------------------------------------
# CLI plumbing
# ---------------------------------------------------------------------------------------------


class TestCLI:
    def test_parser_requires_a_subcommand(self):
        with pytest.raises(SystemExit):
            build_parser().parse_args([])

    def test_the_log_read_budget_is_adjustable_from_the_command_line(self):
        from slurmbar_agent import snapshot as snapshot_mod

        default = build_parser().parse_args(["snapshot"])
        assert default.log_fallback_limit == snapshot_mod.MAX_LOG_FALLBACK_JOBS
        raised = build_parser().parse_args(["snapshot", "--log-fallback-limit", "40"])
        assert raised.log_fallback_limit == 40

    def test_gpu_accepts_repeated_job_ids(self):
        parsed = build_parser().parse_args(
            ["gpu", "--json", "--job-id", "282940_0", "--job-id", "283356_0"]
        )
        assert parsed.job_id == ["282940_0", "283356_0"]

    def test_doctor_emits_json_on_stdout_only(self, capsys, tmp_path: Path, monkeypatch):
        monkeypatch.setenv("SLURMBAR_STATE_DIR", str(tmp_path))
        exit_code = main(["doctor", "--json"])
        captured = capsys.readouterr()
        payload = json.loads(captured.out)
        assert payload["schema_version"] == 1
        assert "checks" in payload
        assert exit_code in (0, 1)

    def test_snapshot_on_a_machine_without_slurm_degrades_instead_of_failing(
        self, capsys, tmp_path: Path
    ):
        import shutil

        exit_code = main(["snapshot", "--json", "--progress-dir", str(tmp_path)])
        payload = json.loads(capsys.readouterr().out)
        assert exit_code == 0  # partial data plus warnings, not a fatal error
        assert payload["schema_version"] == 1
        if shutil.which("squeue") is None:
            assert payload["jobs"] == []
            assert any(w["code"] == "SLURM_MISSING" for w in payload["warnings"])

    def test_invalid_user_exits_nonzero_with_a_structured_error(self, capsys):
        exit_code = main(["snapshot", "--user", "bad user;"])
        payload = json.loads(capsys.readouterr().out)
        assert exit_code == 2
        assert payload["error"]["code"] == "INVALID_ARGUMENT"

    def test_paths_command(self, capsys, tmp_path: Path, monkeypatch):
        monkeypatch.setenv("SLURMBAR_STATE_DIR", str(tmp_path))
        assert main(["paths"]) == 0
        payload = json.loads(capsys.readouterr().out)
        assert payload["progress_state_dir"] == str(tmp_path)

    def test_job_not_found_exits_with_the_not_found_code(self, capsys, tmp_path: Path):
        exit_code = main(["job", "--job-id", "999999", "--progress-dir", str(tmp_path)])
        payload = json.loads(capsys.readouterr().out)
        assert exit_code == 4
        assert payload["error"]["code"] == "NOT_FOUND"
