"""Fatal error types. Nonfatal problems are reported as structured warnings instead."""

from __future__ import annotations


class AgentError(Exception):
    """Base class for fatal agent errors. ``exit_code`` becomes the process exit status."""

    exit_code = 1
    code = "AGENT_ERROR"


class InvalidArgument(AgentError):
    exit_code = 2
    code = "INVALID_ARGUMENT"


class SlurmUnavailable(AgentError):
    exit_code = 3
    code = "SLURM_UNAVAILABLE"


class NotFound(AgentError):
    exit_code = 4
    code = "NOT_FOUND"


class PermissionDenied(AgentError):
    exit_code = 5
    code = "PERMISSION_DENIED"
