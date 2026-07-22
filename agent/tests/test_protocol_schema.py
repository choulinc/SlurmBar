"""The generated payloads must satisfy the published schemas.

This is the contract test that keeps Python and Swift honest: `protocol/schema/*.json` is the
single source of truth, the agent is validated against it here, and the Swift test suite
decodes the very same example files in `protocol/examples/`.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from conftest import FIXTURES, REPO_ROOT, read_fixture
from slurmbar_agent import doctor as doctor_mod
from slurmbar_agent.commands import cancel_job, read_logs
from slurmbar_agent.runner import FakeRunner
from slurmbar_agent.snapshot import build_snapshot

jsonschema = pytest.importorskip("jsonschema", reason="jsonschema is needed for contract tests")

SCHEMA_DIR = REPO_ROOT / "protocol" / "schema"
EXAMPLE_DIR = REPO_ROOT / "protocol" / "examples"


def load_schema(name: str) -> dict:
    return json.loads((SCHEMA_DIR / name).read_text())


def validate(payload: dict, schema_name: str) -> None:
    jsonschema.validate(instance=payload, schema=load_schema(schema_name))


def full_runner() -> FakeRunner:
    runner = FakeRunner()
    runner.stub("squeue --json", read_fixture("squeue", "squeue-json-2311.json"))
    runner.stub(
        "sacct --noheader --parsable2 --allocations",
        read_fixture("sacct", "sacct-allocations.txt"),
    )
    runner.stub(
        "sacct --noheader --parsable2 --starttime=now-24hours",
        read_fixture("sacct", "sacct-steps.txt"),
    )
    runner.stub("sstat", read_fixture("sstat", "sstat-running.txt"))
    runner.stub(
        "scontrol show config",
        "ClusterName            = examplecluster\nSLURM_VERSION          = 23.11.7\n",
    )
    return runner


class TestSchemasAreValid:
    @pytest.mark.parametrize(
        "name",
        [
            "snapshot.schema.json",
            "doctor.schema.json",
            "logs.schema.json",
            "cancel.schema.json",
            "progress-status.schema.json",
        ],
    )
    def test_schema_itself_is_a_valid_json_schema(self, name):
        schema = load_schema(name)
        jsonschema.Draft202012Validator.check_schema(schema)


class TestGeneratedPayloadsConform:
    def test_snapshot(self, tmp_path: Path):
        snapshot = build_snapshot(full_runner(), user="exampleuser", progress_dir=str(tmp_path))
        validate(snapshot, "snapshot.schema.json")

    def test_snapshot_with_structured_progress(self, tmp_path: Path):
        directory = tmp_path / "201551"
        directory.mkdir()
        (directory / "status.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "job_id": "201551",
                    "kind": "training",
                    "phase": "train",
                    "current": 375,
                    "total": 1000,
                    "unit": "epoch",
                    "metrics": {"loss": 0.059045, "note": "warm restart"},
                    "started_at": "2026-07-22T00:10:00Z",
                    "updated_at": "2026-07-22T02:29:55Z",
                    "completion": "running",
                }
            )
        )
        snapshot = build_snapshot(full_runner(), user="exampleuser", progress_dir=str(tmp_path))
        validate(snapshot, "snapshot.schema.json")

    def test_degraded_snapshot_with_warnings(self, tmp_path: Path):
        snapshot = build_snapshot(FakeRunner(available=[]), progress_dir=str(tmp_path))
        validate(snapshot, "snapshot.schema.json")
        assert snapshot["warnings"]

    def test_doctor(self, tmp_path: Path):
        report = doctor_mod.run_doctor(full_runner(), progress_dir=str(tmp_path))
        validate(report, "doctor.schema.json")

    def test_doctor_on_a_broken_cluster(self, tmp_path: Path):
        report = doctor_mod.run_doctor(FakeRunner(available=[]), progress_dir=str(tmp_path))
        validate(report, "doctor.schema.json")

    def test_logs(self, tmp_path: Path):
        log = tmp_path / "job.out"
        log.write_text("hello\nworld\n")
        payload = read_logs(FakeRunner(), "201551", path_override=str(log))
        validate(payload, "logs.schema.json")

    def test_logs_when_the_path_is_unknown(self):
        payload = read_logs(FakeRunner(available=[]), "201551")
        validate(payload, "logs.schema.json")

    def test_cancel_result_shape(self):
        # No scancel is executed: FakeRunner records the argv and returns a canned result.
        runner = FakeRunner()
        runner.stub("scancel", "", returncode=0)
        validate(cancel_job(runner, "201551"), "cancel.schema.json")


class TestCommittedExamples:
    """The example payloads shipped for the Swift tests must stay schema-valid."""

    @pytest.mark.parametrize(
        "filename,schema",
        [
            ("snapshot-full.json", "snapshot.schema.json"),
            ("snapshot-empty.json", "snapshot.schema.json"),
            ("snapshot-degraded.json", "snapshot.schema.json"),
            ("doctor-ok.json", "doctor.schema.json"),
            ("doctor-degraded.json", "doctor.schema.json"),
            ("logs-tail.json", "logs.schema.json"),
            ("cancel-ok.json", "cancel.schema.json"),
            ("progress-status-training.json", "progress-status.schema.json"),
        ],
    )
    def test_example_validates(self, filename, schema):
        payload = json.loads((EXAMPLE_DIR / filename).read_text())
        validate(payload, schema)


def test_every_warning_code_used_by_the_agent_is_declared_in_the_schema():
    from slurmbar_agent.protocol import W

    schema = load_schema("snapshot.schema.json")
    declared = set(schema["$defs"]["warning"]["properties"]["code"]["enum"])
    used = {value for name, value in vars(W).items() if not name.startswith("_")}
    assert used <= declared, f"undeclared warning codes: {sorted(used - declared)}"


def test_every_normalized_state_is_declared_in_the_schema():
    from slurmbar_agent.protocol import NORMALIZED_STATES

    schema = load_schema("snapshot.schema.json")
    declared = set(schema["$defs"]["state"]["enum"])
    assert set(NORMALIZED_STATES) == declared
