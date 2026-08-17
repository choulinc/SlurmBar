from __future__ import annotations

import sys

from slurmbar_agent import runner as runner_mod
from slurmbar_agent.runner import SubprocessRunner


def test_subprocess_output_is_capped_while_the_child_is_running(monkeypatch):
    monkeypatch.setattr(runner_mod, "MAX_OUTPUT_BYTES", 1024)
    result = SubprocessRunner(default_timeout=5).run(
        [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'x' * 100000)"]
    )

    assert result.ok is False
    assert "[slurmbar: output truncated]" in result.stdout
    assert len(result.stdout.encode("utf-8")) <= 1024


def test_stdout_and_stderr_are_drained_concurrently(monkeypatch):
    monkeypatch.setattr(runner_mod, "MAX_OUTPUT_BYTES", 512 * 1024)
    program = (
        "import sys; "
        "sys.stdout.buffer.write(b'o' * 100000); sys.stdout.flush(); "
        "sys.stderr.buffer.write(b'e' * 100000); sys.stderr.flush()"
    )
    result = SubprocessRunner(default_timeout=5).run([sys.executable, "-c", program])

    assert result.ok is True
    assert len(result.stdout) == 100000
    assert len(result.stderr) == 100000


def test_timeout_returns_bounded_partial_output(monkeypatch):
    monkeypatch.setattr(runner_mod, "MAX_OUTPUT_BYTES", 1024)
    program = "import sys,time; print('started', flush=True); time.sleep(5)"
    # Leave enough startup time for the nested interpreter even when the full suite is busy;
    # the five-second sleep still guarantees that this exercises the timeout path.
    result = SubprocessRunner(default_timeout=0.5).run([sys.executable, "-c", program])

    assert result.timed_out is True
    assert result.returncode == 124
    assert result.stdout == "started\n"
    assert len(result.stderr.encode("utf-8")) <= 1024
