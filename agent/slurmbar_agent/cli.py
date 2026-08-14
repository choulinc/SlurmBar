"""``slurmbar-agent`` command line entry point.

Contract with the macOS app:

* JSON goes to stdout and nothing else ever does;
* diagnostics go to stderr;
* exit 0 means "usable payload", even when it carries warnings;
* a nonzero exit means the payload is not usable, and stdout carries a structured error object.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Dict, List, Optional, Sequence

from . import commands, doctor as doctor_mod, snapshot as snapshot_mod
from .errors import AgentError
from .progress import DEFAULT_STALE_SECONDS, default_state_dir
from .protocol import AGENT_VERSION, SCHEMA_VERSION
from .runner import SubprocessRunner
from .timeutil import iso_utc, utc_now
from .validate import validate_user


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="slurmbar-agent",
        description="Collect Slurm job state for SlurmBar. Prints JSON to stdout.",
    )
    parser.add_argument("--version", action="version", version=f"slurmbar-agent {AGENT_VERSION}")
    parser.add_argument(
        "--timeout",
        type=float,
        default=15.0,
        help="Per-Slurm-command timeout in seconds (default: 15).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_json_flag(p: argparse.ArgumentParser) -> None:
        # --json is accepted for explicitness; JSON is the only output format.
        p.add_argument("--json", action="store_true", default=True, help="Emit JSON (default).")

    doctor = sub.add_parser("doctor", help="Check SSH, Python, Slurm and progress availability.")
    add_json_flag(doctor)
    doctor.add_argument("--progress-dir", default=None)
    doctor.add_argument("--user", default=None)

    snap = sub.add_parser("snapshot", help="Collect the current queue, history and progress.")
    add_json_flag(snap)
    snap.add_argument("--user", default=None, help="Slurm user to query (default: the SSH user).")
    snap.add_argument(
        "--all-users",
        action="store_true",
        help="Query every user's jobs instead of just your own. Much larger and slower.",
    )
    snap.add_argument("--history-hours", type=int, default=snapshot_mod.DEFAULT_HISTORY_HOURS)
    snap.add_argument("--progress-dir", default=None)
    snap.add_argument("--progress-stale-seconds", type=int, default=DEFAULT_STALE_SECONDS)
    snap.add_argument("--no-log-fallback", action="store_true", help="Disable log-tail progress parsing.")
    snap.add_argument(
        "--log-fallback-limit",
        type=int,
        default=snapshot_mod.MAX_LOG_FALLBACK_JOBS,
        help=(
            "How many running jobs may have their logs read for progress per refresh "
            f"(default: {snapshot_mod.MAX_LOG_FALLBACK_JOBS}). Raising it costs one filesystem "
            "read per extra job, per stream, per poll."
        ),
    )
    snap.add_argument("--no-sstat", action="store_true", help="Skip live memory collection.")

    job = sub.add_parser("job", help="Full detail for one job (on demand).")
    add_json_flag(job)
    job.add_argument("--job-id", required=True)
    job.add_argument("--progress-dir", default=None)
    job.add_argument("--history-hours", type=int, default=48)

    logs = sub.add_parser("logs", help="Bounded tail of a job's stdout or stderr.")
    add_json_flag(logs)
    logs.add_argument("--job-id", required=True)
    logs.add_argument("--stream", choices=("stdout", "stderr"), default="stdout")
    logs.add_argument("--lines", type=int, default=200)
    logs.add_argument("--path", default=None, help="Known log path from a previous snapshot.")

    cancel = sub.add_parser("cancel", help="Cancel a job (destructive; requires --confirm).")
    add_json_flag(cancel)
    cancel.add_argument("--job-id", required=True)
    cancel.add_argument(
        "--confirm",
        action="store_true",
        help="Required. Without it the command refuses to run.",
    )

    paths = sub.add_parser("paths", help="Print the paths this agent reads.")
    add_json_flag(paths)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    runner = SubprocessRunner(default_timeout=args.timeout)

    try:
        payload = _dispatch(args, runner)
    except AgentError as exc:
        _emit(_error_payload(exc.code, str(exc)))
        print(f"slurmbar-agent: {exc}", file=sys.stderr)
        return exc.exit_code
    except KeyboardInterrupt:  # pragma: no cover
        return 130
    except Exception as exc:  # unexpected: still emit machine-readable output
        _emit(_error_payload("INTERNAL_ERROR", f"{type(exc).__name__}: {exc}"))
        print(f"slurmbar-agent: internal error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    _emit(payload)
    return 0


def _dispatch(args: argparse.Namespace, runner: SubprocessRunner) -> Dict[str, Any]:
    if args.command == "doctor":
        return doctor_mod.run_doctor(
            runner,
            progress_dir=args.progress_dir,
            user=validate_user(args.user),
            timeout=args.timeout,
        )

    if args.command == "snapshot":
        return snapshot_mod.build_snapshot(
            runner,
            user=validate_user(args.user),
            all_users=args.all_users,
            history_hours=max(0, args.history_hours),
            progress_dir=args.progress_dir,
            stale_seconds=max(10, args.progress_stale_seconds),
            enable_log_fallback=not args.no_log_fallback,
            log_fallback_limit=max(0, args.log_fallback_limit),
            enable_sstat=not args.no_sstat,
            timeout=args.timeout,
        )

    if args.command == "job":
        return commands.job_detail(
            runner,
            args.job_id,
            progress_dir=args.progress_dir,
            history_hours=max(1, args.history_hours),
            timeout=args.timeout,
        )

    if args.command == "logs":
        return commands.read_logs(
            runner,
            args.job_id,
            stream=args.stream,
            lines=args.lines,
            path_override=args.path,
            timeout=args.timeout,
        )

    if args.command == "cancel":
        if not args.confirm:
            from .errors import InvalidArgument

            raise InvalidArgument(
                "cancel requires --confirm. SlurmBar passes it only after the user confirms "
                "the cancellation in the UI."
            )
        return commands.cancel_job(runner, args.job_id, timeout=args.timeout)

    if args.command == "paths":
        return {
            "schema_version": SCHEMA_VERSION,
            "generated_at": iso_utc(utc_now()),
            "agent_version": AGENT_VERSION,
            "progress_state_dir": default_state_dir(),
            "python": sys.executable,
        }

    raise AssertionError(f"unhandled command {args.command!r}")  # pragma: no cover


def _emit(payload: Dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"), default=str)
    sys.stdout.write("\n")
    sys.stdout.flush()


def _error_payload(code: str, message: str) -> Dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": iso_utc(utc_now()),
        "agent_version": AGENT_VERSION,
        "error": {"code": code, "message": message},
    }


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
