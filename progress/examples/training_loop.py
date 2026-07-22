#!/usr/bin/env python3
"""Minimal training-loop integration for SlurmBar.

Run it anywhere — inside a Slurm job it picks up ``$SLURM_JOB_ID`` automatically, and on a
laptop it writes under a ``local-<pid>`` id so you can see the output without a cluster:

    python3 training_loop.py

Then look at the file it prints, or run ``slurmbar-agent snapshot --json``.
"""

from __future__ import annotations

import math
import random
import time

from slurmbar_progress import ProgressReporter

TOTAL_EPOCHS = 20
BATCHES_PER_EPOCH = 94


def train_one_epoch(epoch: int, reporter: ProgressReporter) -> float:
    """Pretend to train. The reporter is called every batch on purpose."""
    loss = 0.0
    for batch in range(1, BATCHES_PER_EPOCH + 1):
        time.sleep(0.005)
        loss = math.exp(-epoch / 6.0) + random.uniform(0, 0.01)

        # Calling this ~1900 times per run is fine: the reporter rate-limits writes to one
        # every 5 s by default, so the shared filesystem sees a trickle, not a flood.
        reporter.update(
            current=epoch,
            total=TOTAL_EPOCHS,
            unit="epoch",
            phase="train",
            metrics={
                "loss": float(loss),
                "learning_rate": 3.4e-05,
                "batch_current": batch,
                "batch_total": BATCHES_PER_EPOCH,
            },
        )
    return loss


def main() -> None:
    # The context manager marks the job completed on a clean exit and failed on an exception,
    # so a crashed run shows up in SlurmBar as "failed at epoch N" rather than going silent.
    with ProgressReporter(kind="training") as reporter:
        print(f"Writing progress to {reporter.status_path}")

        for epoch in range(1, TOTAL_EPOCHS + 1):
            loss = train_one_epoch(epoch, reporter)

            # A phase change forces an immediate write, so the end of each epoch is never lost.
            reporter.update(phase="validate", message=f"Validating after epoch {epoch}")
            time.sleep(0.05)
            reporter.update(phase="train", metrics={"val_loss": float(loss) * 1.05})

            print(f"epoch {epoch}/{TOTAL_EPOCHS} loss={loss:.6f}")

        reporter.message("Saving final checkpoint")


if __name__ == "__main__":
    main()
