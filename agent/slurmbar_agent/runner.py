"""Command execution abstraction.

Everything the agent shells out to goes through :class:`CommandRunner`. Tests inject
:class:`FakeRunner` so the whole parsing and assembly pipeline runs without Slurm installed.

Two invariants:

* commands are always ``argv`` lists — ``shell=True`` is never used anywhere in the agent;
* output is always bounded, so a pathological command cannot exhaust login-node memory.
"""

from __future__ import annotations

import os
import selectors
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from typing import Dict, List, Mapping, Optional, Protocol, Sequence, Tuple

DEFAULT_TIMEOUT = 20.0
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
READ_CHUNK_BYTES = 64 * 1024
POST_EXIT_GRACE_SECONDS = 0.25
_TRUNCATION_MARKER = b"\n[slurmbar: output truncated]\n"


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


def _decode_captured(raw: bytes, truncated: bool = False) -> str:
    if truncated:
        room = max(0, MAX_OUTPUT_BYTES - len(_TRUNCATION_MARKER))
        raw = raw[:room] + _TRUNCATION_MARKER
    return raw.decode("utf-8", errors="replace")


class SubprocessRunner:
    """Real runner. Uses ``Popen`` with bounded output, an explicit timeout, and no shell."""

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
            process = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=merged_env,
            )
        except FileNotFoundError:
            return CommandResult(
                argv, 127, "", f"{argv[0]}: not found", time.monotonic() - started, not_found=True
            )
        except PermissionError as exc:
            return CommandResult(argv, 126, "", str(exc), time.monotonic() - started)

        effective_timeout = timeout if timeout is not None else self.default_timeout
        stdout, stderr, returncode, timed_out, stdout_truncated, stderr_truncated = (
            _capture_process(process, effective_timeout)
        )
        return CommandResult(
            argv,
            124 if timed_out else returncode,
            _decode_captured(stdout, stdout_truncated),
            _decode_captured(stderr, stderr_truncated),
            time.monotonic() - started,
            timed_out=timed_out,
        )


def _capture_process(
    process: subprocess.Popen, timeout: float
) -> Tuple[bytes, bytes, int, bool, bool, bool]:
    """Drain both pipes concurrently while retaining at most ``MAX_OUTPUT_BYTES`` each.

    ``subprocess.run(capture_output=True)`` only lets callers truncate *after* the child exits,
    so a noisy or hostile Slurm command can exhaust the login node first. Non-blocking reads keep
    memory bounded while also avoiding the stdout/stderr pipe deadlock.
    """
    selector = selectors.DefaultSelector()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    truncated = {"stdout": False, "stderr": False}
    streams = {"stdout": process.stdout, "stderr": process.stderr}

    for name, stream in streams.items():
        if stream is None:  # pragma: no cover - Popen above always requests both pipes
            continue
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ, data=name)

    deadline = time.monotonic() + max(0.0, float(timeout))
    process_exited_at: Optional[float] = None
    timed_out = False
    exceeded_limit = False

    try:
        while selector.get_map():
            now = time.monotonic()
            if now >= deadline:
                timed_out = True
                _kill(process)
                _drain_stopped_process(selector, buffers, truncated)
                break

            events = selector.select(timeout=min(0.1, max(0.0, deadline - now)))
            for key, _ in events:
                name = key.data
                try:
                    chunk = os.read(key.fd, READ_CHUNK_BYTES)
                except BlockingIOError:
                    continue
                except OSError:
                    chunk = b""

                if not chunk:
                    try:
                        selector.unregister(key.fileobj)
                    except (KeyError, ValueError):
                        pass
                    try:
                        key.fileobj.close()
                    except OSError:
                        pass
                    continue

                target = buffers[name]
                room = max(0, MAX_OUTPUT_BYTES - len(target))
                if room:
                    target.extend(chunk[:room])
                if len(chunk) > room:
                    truncated[name] = True
                    exceeded_limit = True
                    _kill(process)
                    break

            if exceeded_limit:
                break

            if process.poll() is not None:
                if process_exited_at is None:
                    process_exited_at = time.monotonic()
                elif time.monotonic() - process_exited_at >= POST_EXIT_GRACE_SECONDS:
                    # A descendant may have inherited a pipe. Do not wait forever for its EOF.
                    break

        if process.poll() is None:
            remaining = max(0.0, deadline - time.monotonic())
            try:
                process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                timed_out = True
                _kill(process)
        if process.poll() is None:  # pragma: no cover - kill should make this immediate
            process.wait()
    finally:
        for key in list(selector.get_map().values()):
            try:
                selector.unregister(key.fileobj)
            except (KeyError, ValueError):
                pass
            try:
                key.fileobj.close()
            except OSError:
                pass
        selector.close()

    return (
        bytes(buffers["stdout"]),
        bytes(buffers["stderr"]),
        process.returncode if process.returncode is not None else -1,
        timed_out,
        truncated["stdout"],
        truncated["stderr"],
    )


def _kill(process: subprocess.Popen) -> None:
    if process.poll() is None:
        try:
            process.kill()
        except ProcessLookupError:
            pass


def _drain_stopped_process(
    selector: selectors.BaseSelector,
    buffers: Dict[str, bytearray],
    truncated: Dict[str, bool],
) -> None:
    """Preserve already-written output after stopping a timed-out child.

    Pipes stay non-blocking and the short deadline also covers descendants that inherited a
    descriptor, so timeout handling cannot turn into an unbounded wait.
    """
    deadline = time.monotonic() + POST_EXIT_GRACE_SECONDS
    while selector.get_map() and time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        events = selector.select(timeout=min(0.02, remaining))
        for key, _ in events:
            name = key.data
            try:
                chunk = os.read(key.fd, READ_CHUNK_BYTES)
            except BlockingIOError:
                continue
            except OSError:
                chunk = b""

            if not chunk:
                try:
                    selector.unregister(key.fileobj)
                except (KeyError, ValueError):
                    pass
                try:
                    key.fileobj.close()
                except OSError:
                    pass
                continue

            target = buffers[name]
            room = max(0, MAX_OUTPUT_BYTES - len(target))
            if room:
                target.extend(chunk[:room])
            if len(chunk) > room:
                truncated[name] = True


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
