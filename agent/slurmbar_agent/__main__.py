"""Entry point for ``python3 -m slurmbar_agent`` and for the zipapp."""

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
