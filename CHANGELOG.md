# Changelog

Notable changes per release. Dates are the release date, not the last commit.

## 0.2.1 — 2026-07-22

Public-release preparation:

- Replaced demo data and production-shaped regression values with explicitly fictional
  `demo-*`, `example*` and `.invalid` identifiers; removed older job screenshots pending a new
  synthetic-only capture.
- Added a GitHub-recognized security policy and continuous integration for the Python and Swift
  suites.
- Removed brittle hard-coded test totals from the README.
- Aligned the release version with the current source tree.

## 0.2.0 — 2026-07-22

First release validated with an opt-in live-cluster check. Everything in 0.1.0 was
fixture-driven; this one fixed compatibility issues that synthetic data had missed.

### Fixed — real-cluster compatibility

- **The app could not talk to a cluster at all.** `ShellQuoting.join` single-quoted the whole
  agent path, so `~` never expanded and the remote Python tried to open `$HOME/~/.local/...`.
- **Scoped to the invoking user.** The agent defaulted to every job visible on the cluster and
  then tried to read other users' log files. Added `--all-users` for the old behaviour.
- **Log paths were unusable.** Slurm 25.11's `squeue --json` returns the *unexpanded* pattern
  (`%x-%A_%a.out`). It is now expanded; a pattern that cannot be fully resolved reports no path
  rather than a broken one.
- **Memory was overstated.** `memory_per_node` could be a constant node-level figure unrelated
  to an individual job's request. Memory now comes from TRES.
- **Array tasks shared one memory figure.** `sstat` answers array queries with the tasks'
  underlying job ids, so every task fell back to the array parent's number. Added
  `slurm_job_id` to the protocol and match on it.
- **Running jobs claimed `exit 0`.** Slurm reports an exit code for jobs that have not exited;
  active jobs now report none, from either `squeue` or the `sacct` merge.
- `signal {"set": false}` decoded as signal 0 rather than "no signal".
- `install-agent.sh` checked whether `scp` exists locally rather than whether it works. It now
  falls back to piping over `ssh`, verifies the transferred size, and backs up any previous
  agent.
- Log parser missed `avg_loss:` (no word boundary before "loss") and bracketed batch position
  `Epoch 35 [27/94]` (no "batch" keyword).

### Added

- **The popover opens when you launch or double-click the app.** A menu bar app otherwise gives
  no feedback at all — the icon is already there, so double-clicking appeared to do nothing.
  `MenuBarExtra` has no API for this, so the status item is found and clicked through AppKit,
  guarded so a future macOS that changes the layout degrades to today's behaviour rather than
  crashing. Opening is idempotent: double-clicking while the popover is open leaves it open
  instead of toggling it shut.
- **A one-time prompt to start at login**, shown after you have seen the popover once and only
  when a cluster is configured. Settings now reports what macOS actually thinks — registered,
  awaiting your approval, or unavailable — with a button to open Login Items, instead of a
  toggle that could be silently ineffective.
- **Screenshots in the README**, taken from demo mode so no real job or account name appears.
- **Interactive-login failures are their own error.** Clusters requiring an OTP fail
  `BatchMode` with `Permission denied (keyboard-interactive)`. The advice now points at
  Terminal and `ControlPersist` instead of sending you to chase `ssh-add`.
- **Opt-in live-cluster tests** — `SLURMBAR_LIVE_ALIAS=<alias> swift test --filter
  LiveClusterTests`. These exercise the real `/usr/bin/ssh` path and are what surfaced the
  quoting bug that fixture tests structurally could not.
- **App icon**, generated into a full `.icns` set at build time by `scripts/make-app-icon.sh`.
- **A Quickstart in the README** written for someone who has not set up SSH before.
- `VERSION` as the single source of truth, with `scripts/set-version.sh` and a test that fails
  when the five copies drift.

### Changed — interface

- **The popover sizes itself to the job list**, capped at 80% of the screen's usable height
  rather than a fixed 520pt slab.
- **Job detail is a page inside the popover**, not a sheet. Opening a sheet moved key focus and
  macOS closed the popover underneath it, so closing the detail left nothing on screen. It also
  now shares the list's width, type scale and spacing.
- **Finished jobs can be removed from the list** — per job, all cancelled, or all finished —
  from a trash menu in the header or a right-click. Removals persist per cluster, are capped,
  and are pruned when the cluster stops reporting the job. "Always hide failed/cancelled"
  remains available for the automatic case.
- **Completed jobs sit in their own section**, separate from failed and cancelled ones. The
  two demand different attention: a completed run is a result to collect, an unsuccessful one
  is something to look into. Previously a batch of clean completions could push a failure out
  of sight.
- **Colours follow meaning**: a running job's icon is the same blue as its progress bar so the
  row reads as one object, and a completed job is green rather than grey.
- **No progress bar on a completed job.** A bar answers "how far along is this?", which is
  settled once a job has finished. A run that stopped at epoch 652 of 1000 and exited cleanly
  did not reach 1000, so filling the bar would claim something untrue; leaving it at 65% next to
  "Completed" reads as unfinished. The bar and percentage are dropped and the counter, which is
  factual, is kept. Failures keep their bar — how far they got is exactly what you want to know.
- **Counts always match the list.** The summary strip and menu bar previously used the agent's
  own counts over a wider window, so the header could read "7 failed" above a section showing
  three. Both now derive from exactly the jobs on screen.

### Note

Removing a finished job affects this Mac's list only. A finished job cannot be deleted from
Slurm — `sacct` will still report it — and nothing in SlurmBar claims otherwise.

## 0.1.0 — 2026-07-22

Initial MVP: SwiftUI menu bar app, one-shot Python agent, structured progress SDK, versioned
JSON protocol, and a fixture-driven test suite. Not yet validated against a live cluster.
