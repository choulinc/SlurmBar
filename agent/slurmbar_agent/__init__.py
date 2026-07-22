"""slurmbar-agent — one-shot Slurm data collector for SlurmBar.

Runs on a cluster login node, gathers Slurm state, prints one JSON document, exits. No daemon,
no listening port, no root, no third-party dependencies.
"""

from .protocol import AGENT_VERSION, SCHEMA_VERSION

__version__ = AGENT_VERSION
__all__ = ["AGENT_VERSION", "SCHEMA_VERSION", "__version__"]
