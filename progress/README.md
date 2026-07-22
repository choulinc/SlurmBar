# slurmbar_progress

Optional structured progress reporting for Slurm workloads, readable by
[SlurmBar](../README.md).

Slurm knows your job is `RUNNING`. It does not know it is on epoch 375 of 1000 with a loss of
0.059. This is how the job says so.

Pure Python standard library, 3.7+.

## Usage

```python
from slurmbar_progress import ProgressReporter

reporter = ProgressReporter(kind="training")

for epoch in range(start_epoch, total_epochs):
    loss = train_one_epoch()

    reporter.update(
        current=epoch + 1,
        total=total_epochs,
        unit="epoch",
        phase="train",
        metrics={
            "loss": float(loss),
            "learning_rate": float(lr),
            "batch_current": batch_index,
            "batch_total": total_batches,
        },
    )

reporter.complete(message="Training finished")
```

Or as a context manager, so a crash is recorded rather than going silent:

```python
with ProgressReporter(kind="training") as reporter:
    ...   # completed on clean exit, failed (with the exception) on a crash
```

## Non-training workloads

The model is a counter, an optional total, a unit, and free-form metrics — nothing about it is
specific to machine learning.

```python
ProgressReporter(kind="preprocessing").update(current=files_done, unit="file")   # total unknown
ProgressReporter(kind="simulation").update(current=step, total=n_steps, unit="timestep")
ProgressReporter(kind="sweep").update(current=trial, total=n_trials, unit="trial")
```

When `total` is unknown, leave it `None`: SlurmBar shows "4,820 files" with no progress bar
rather than inventing a percentage. Call `set_total()` once you know it.

See [`examples/`](examples/).

## Behaviour worth knowing

* **Job identity is automatic.** `$SLURM_JOB_ID`, or `<array_job>_<task>` inside an array task —
  matching what `squeue` displays. Outside Slurm it uses `local-<pid>`, so scripts run on a
  laptop.
* **Calling it every batch is fine.** Writes are rate-limited to one per 5 s by default. Phase
  changes, `complete()` and `fail()` always force a write, so the interesting moments are never
  dropped.
* **It cannot break your job.** Every method — including the constructor — catches its own
  exceptions and logs to stderr at most. A full disk degrades SlurmBar's display; it does not
  kill a 40-hour run.
* **Writes are atomic.** Temp file in the same directory → `fsync` → `os.replace`. A reader
  concurrent with a write sees either the whole old document or the whole new one, never a torn
  one.
* **NaN survives.** NaN and infinity are written as `"nan"` / `"inf"` strings, because JSON
  can't carry them and a NaN loss is worth a notification.

## Location

`~/.local/state/slurmbar/jobs/<job_id>/status.json`, overridable with `$SLURMBAR_STATE_DIR` or
the `state_dir=` argument. It must be readable from the **login node** — a node-local `/tmp`
will not work.

## Development

```bash
cd progress && ../.venv/bin/python -m pytest tests/ -q
```

44 tests, including a round-trip suite that writes with the SDK and reads with the agent.
