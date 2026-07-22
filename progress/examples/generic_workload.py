#!/usr/bin/env python3
"""Non-training workloads report progress the same way.

Nothing about SlurmBar's progress model is specific to machine learning: it is a counter, an
optional total, a unit, and free-form metrics. This shows three shapes:

* a preprocessing job with an unknown total (a pure item counter),
* a simulation reporting timesteps,
* a parameter sweep reporting trials.

    python3 generic_workload.py preprocessing
"""

from __future__ import annotations

import sys
import time

from slurmbar_progress import ProgressReporter


def preprocessing() -> None:
    """Total unknown until the directory walk finishes — `total` stays None until it is known."""
    with ProgressReporter(kind="preprocessing", job_id="example-preprocess") as reporter:
        print(f"Writing progress to {reporter.status_path}")
        reporter.message("Scanning input directory")

        discovered = 0
        for _ in range(40):
            time.sleep(0.01)
            discovered += 1
            # No total yet: SlurmBar shows "1,234 files" with no progress bar rather than a
            # fake percentage.
            reporter.update(current=discovered, unit="file", phase="scan")

        reporter.set_total(discovered, force=True)
        for converted in range(1, discovered + 1):
            time.sleep(0.01)
            reporter.update(current=converted, phase="convert", unit="file")

        reporter.complete(message=f"Converted {discovered} files")


def simulation() -> None:
    total_steps = 500
    with ProgressReporter(kind="simulation", job_id="example-simulation") as reporter:
        print(f"Writing progress to {reporter.status_path}")
        for step in range(1, total_steps + 1):
            time.sleep(0.002)
            reporter.update(
                current=step,
                total=total_steps,
                unit="timestep",
                phase="solve",
                metrics={"residual": 1.0 / step, "cfl": 0.9},
            )
        reporter.complete(message="Converged")


def sweep() -> None:
    trials = 12
    with ProgressReporter(kind="sweep", job_id="example-sweep") as reporter:
        print(f"Writing progress to {reporter.status_path}")
        best = None
        for trial in range(1, trials + 1):
            time.sleep(0.02)
            score = 1.0 / trial
            best = score if best is None else min(best, score)
            reporter.update(
                current=trial,
                total=trials,
                unit="trial",
                phase="search",
                metrics={"best_score": best, "last_score": score},
            )
        reporter.complete(message=f"Best score {best:.4f}")


WORKLOADS = {"preprocessing": preprocessing, "simulation": simulation, "sweep": sweep}


def main() -> int:
    name = sys.argv[1] if len(sys.argv) > 1 else "preprocessing"
    workload = WORKLOADS.get(name)
    if workload is None:
        print(f"unknown workload {name!r}; choose from {', '.join(WORKLOADS)}", file=sys.stderr)
        return 2
    workload()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
