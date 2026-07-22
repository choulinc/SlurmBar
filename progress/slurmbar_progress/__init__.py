"""slurmbar_progress — optional structured progress reporting for Slurm workloads.

Slurm can tell SlurmBar that a job is RUNNING and how much memory it peaked at. It cannot tell
SlurmBar which epoch the job is on. Three lines make that visible::

    from slurmbar_progress import ProgressReporter

    reporter = ProgressReporter(kind="training")
    reporter.update(current=epoch + 1, total=total_epochs, unit="epoch",
                    metrics={"loss": float(loss)})

Pure standard library. Never raises into the workload.
"""

from ._atomic import atomic_write_json
from .reporter import (
    COMPLETION_COMPLETED,
    COMPLETION_FAILED,
    COMPLETION_RUNNING,
    DEFAULT_MIN_INTERVAL_SECONDS,
    SCHEMA_VERSION,
    ProgressReporter,
    default_state_dir,
    detect_job_id,
)

__version__ = "0.2.1"

__all__ = [
    "ProgressReporter",
    "SCHEMA_VERSION",
    "DEFAULT_MIN_INTERVAL_SECONDS",
    "COMPLETION_RUNNING",
    "COMPLETION_COMPLETED",
    "COMPLETION_FAILED",
    "default_state_dir",
    "detect_job_id",
    "atomic_write_json",
    "__version__",
]
