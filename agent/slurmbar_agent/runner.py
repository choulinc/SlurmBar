"""Command execution abstraction.

Everything the agent shells out to goes through :class:`CommandRunner`. Tests inject
:class:`FakeRunner` so the whole parsing and assembly pipeline runs without Slurm installed.

Two invariants:

* commands are always ``argv`` lists — ``shell=True`` is never used anywhere in the agent;
* output is always bounded, so a pathological command cannot exhaust login-node memory.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from typing import Dict, List, Mapping, Optional, Protocol, Sequence

DEFAULT_TIMEOUT = 20.0
MAX_OUTPUT_BYTES = 8 * 1024 * 1024


@dataclass(frozen=True)
class CommandResult:
    argv: Sequence[str]
    returncode: int
    stdout: str
    stderr: str
    duration_seconds: float = 0.0
    timed_out: bool = False
    not_found: bool = False

    @property
    def ok(self) -> bool:
        return self.returncode == 0 and not self.timed_out and not self.not_found

    def failure_summary(self) -> str:
        if self.not_found:
            return f"{self.argv[0]}: command not found"
        if self.timed_out:
            return f"{self.argv[0]}: timed out"
        detail = (self.stderr or self.stdout or "").strip().splitlines()
        first = detail[0] if detail else ""
        return f"{self.argv[0]}: exit {self.returncode}{': ' + first if first else ''}"


class CommandRunner(Protocol):
    def run(
        self,
        argv: Sequence[str],
        timeout: Optional[float] = None,
        env: Optional[Mapping[str, str]] = None,
    ) -> CommandResult: ...

    def which(self, program: str) -> Optional[str]: ...


def _truncate(text: str, limit: int = MAX_OUTPUT_BYTES) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + "\n[slurmbar: output truncated]\n"


class SubprocessRunner:
    """Real runner. Uses ``subprocess.run`` with an explicit timeout and no shell."""

    def __init__(self, default_timeout: float = DEFAULT_TIMEOUT) -> None:
        self.default_timeout = default_timeout
        self._which_cache: Dict[str, Optional[str]] = {}

    def which(self, program: str) -> Optional[str]:
        if program not in self._which_cache:
            self._which_cache[program] = shutil.which(program)
        return self._which_cache[program]

    def run(
        self,
        argv: Sequence[str],
        timeout: Optional[float] = None,
        env: Optional[Mapping[str, str]] = None,
    ) -> CommandResult:
        argv = list(argv)
        started = time.monotonic()
        merged_env = dict(os.environ)
        if env:
            merged_env.update(env)
        # Keep Slurm's output stable regardless of the user's locale/environment.
        merged_env.setdefault("SLURM_TIME_FORMAT", "standard")
        merged_env["LC_ALL"] = "C"
        try:
            completed = subprocess.run(
                argv,
                capture_output=True,
                timeout=timeout if timeout is not None else self.default_timeout,
                env=merged_env,
                check=False,
            )
        except FileNotFoundError:
            return CommandResult(
                argv, 127, "", f"{argv[0]}: not found", time.monotonic() - started, not_found=True
            )
        except PermissionError as exc:
            return CommandResult(argv, 126, "", str(exc), time.monotonic() - started)
        except subprocess.TimeoutExpired as exc:
            partial_out = _decode(exc.stdout)
            partial_err = _decode(exc.stderr)
            return CommandResult(
                argv, 124, partial_out, partial_err, time.monotonic() - started, timed_out=True
            )
        return CommandResult(
            argv,
            completed.returncode,
            _decode(completed.stdout),
            _decode(completed.stderr),
            time.monotonic() - started,
        )


def _decode(raw: Optional[bytes]) -> str:
    if not raw:
        return ""
    return _truncate(raw.decode("utf-8", errors="replace"))


@dataclass
class FakeRunner:
    """Deterministic runner for tests.

    ``responses`` maps a lookup key to a :class:`CommandResult`. The key is matched against, in
    order: the full argv joined by spaces, then progressively shorter argv prefixes, then the
    program name alone. That lets a test stub ``"squeue"`` broadly or a precise invocation
    narrowly.
    """

    responses: Dict[str, CommandResult] = field(default_factory=dict)
    available: Optional[Sequence[str]] = None
    calls: List[List[str]] = field(default_factory=list)

    def which(self, program: str) -> Optional[str]:
        if self.available is None:
            return f"/usr/bin/{program}"
        return f"/usr/bin/{program}" if program in self.available else None

    def run(
        self,
        argv: Sequence[str],
        timeout: Optional[float] = None,
        env: Optional[Mapping[str, str]] = None,
    ) -> CommandResult:
        argv = list(argv)
        self.calls.append(argv)
        for size in range(len(argv), 0, -1):
            key = " ".join(argv[:size])
            if key in self.responses:
                stub = self.responses[key]
                return CommandResult(
                    argv,
                    stub.returncode,
                    stub.stdout,
                    stub.stderr,
                    stub.duration_seconds,
                    stub.timed_out,
                    stub.not_found,
                )
        if self.which(argv[0]) is None:
            return CommandResult(argv, 127, "", f"{argv[0]}: not found", not_found=True)
        return CommandResult(argv, 0, "", "")

    # -- convenience constructors used by tests -------------------------------------------

    def stub(self, key: str, stdout: str = "", returncode: int = 0, stderr: str = "") -> "FakeRunner":
        self.responses[key] = CommandResult([key], returncode, stdout, stderr)
        return self

    def stub_missing(self, key: str) -> "FakeRunner":
        self.responses[key] = CommandResult([key], 127, "", "not found", not_found=True)
        return self

    def stub_timeout(self, key: str) -> "FakeRunner":
        self.responses[key] = CommandResult([key], 124, "", "timed out", timed_out=True)
        return self
