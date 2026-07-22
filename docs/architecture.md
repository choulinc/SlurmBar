# Architecture

## The shape of the system

```
  Mac (SlurmBar.app)                    Login node                     Compute node
  ──────────────────                    ──────────                     ────────────
  ClusterMonitor
      │ every 12–75 s
      ▼
  AgentClient  ─── argv ───►  SSHCommandRunner
                                   │
                                   ▼
                             /usr/bin/ssh  ────────►  slurmbar-agent.pyz
                                   ▲                        │
                                   │                        ├─ squeue  (1 call)
                                   │                        ├─ sacct   (2 calls)
                                   │                        ├─ sstat   (1 call)
                                   │                        ├─ scontrol show config (1)
                                   │                        │
                                   │                        ├─ read <state_dir>/<job>/status.json
                                   │                        │        ▲
                                   │                        │        └── written by ────────► slurmbar_progress
                                   │                        │            the workload           inside the job
                                   │                        └─ read tail of stdout (fallback)
                                   │                        │
                                   └──── normalized JSON ◄──┘
```

Everything crosses one boundary — a single JSON document defined in `protocol/schema/` — and
that boundary is where the design decisions concentrate.

## Why this shape

### Why not `slurmrestd`?

Most clusters don't run it, and getting it enabled means asking an admin. SSH already works
everywhere Slurm does, already has the user's credentials, and already has the right
authorization model: the agent can see exactly what the user can see, no more.

### Why a one-shot agent instead of a daemon?

A daemon on a shared login node is something a sysadmin can legitimately object to. A one-shot
process that runs for ~200 ms and exits is indistinguishable from the user typing `squeue`. It
needs no port, no supervision, no cleanup, and no permission beyond the user's own account.

### Why parse Slurm on the *remote* side?

Two reasons, one obvious and one not.

The obvious one: it keeps the app's input surface small and versioned. The Mac decodes one
schema instead of five Slurm output formats across four Slurm versions.

The non-obvious one: **timezones**. Slurm's text output emits timezone-naive local timestamps
(`2026-07-22T00:10:00`). Only something running on the login node knows what zone that is. The
agent converts to UTC; the Mac never has to guess.

### Why SwiftPM instead of a checked-in `.xcodeproj`?

An `.xcodeproj` is a large generated file that conflicts on every merge and can't be built or
tested from a terminal without Xcode-specific invocations. A `Package.swift` builds and tests
with `swift build` / `swift test`, opens in Xcode via `xed app/`, and is readable in a diff.

The trade-off is that SwiftPM produces a bare executable, and a menu bar app needs a real bundle
for `LSUIElement`, `UNUserNotificationCenter` and `SMAppService`.
`scripts/build-macos-app.sh` assembles and ad-hoc signs one.

## macOS side

### Layering

`SlurmBarKit` (library) holds **all** logic. `SlurmBar` (executable) holds **only** SwiftUI
views. This split is what makes the app testable: polling policy, error categorization, job
grouping, notification transitions and formatting are all pure types with no view dependency,
covered by a fixture-driven test suite.

| Area | Type | Responsibility |
| --- | --- | --- |
| Protocol | `ProtocolDecoder` | Size limit → schema check → structured error → decode. |
| | `SanitizedText` | Strips ANSI/control/bidi from every remote string. |
| SSH | `ShellQuoting` | POSIX quoting for the *remote* shell. |
| | `SSHCommandRunner` | Builds the `ssh` argv. `BatchMode=yes`, no host-key weakening. |
| | `ProcessRunner` | Timeout, cancellation, concurrent pipe draining. |
| | `SSHErrorClassifier` | OpenSSH stderr → one of 16 categorized failures. |
| Agent | `AgentClient` | Composes remote argv; validates job ids before they become arguments. |
| Policy | `PollingPolicy` | Pure function: context → next interval. No timers inside. |
| | `StalenessPolicy` | Snapshot age → fresh/aging/stale. |
| State | `ClusterMonitor` | `@MainActor`. One refresh in flight; cache; on-demand actions. |
| | `JobEventDetector` | Snapshot stream → notification-worthy transitions. |
| Display | `JobGrouper`, `MenuBarLabelBuilder`, `Formatters` | Pure presentation logic. |

### Concurrency

`ClusterMonitor` is `@MainActor`, which makes its published state safe to read from SwiftUI
without further synchronization. The one place with genuine cross-thread state is
`ProcessRunner`: `terminationHandler`, two readability handlers and a timeout timer all fire on
independent queues, and exactly one of them must resume the continuation. That is handled by a
lock-guarded state object with a single `finish(with:)` path.

Two subtleties in `ProcessRunner` worth preserving:

1. **stdout and stderr are drained concurrently.** Reading one to completion first deadlocks as
   soon as the process fills the 64 KiB pipe buffer of the other — which a large snapshot does.
2. **Exit is detected from `terminationHandler`, not from EOF.** With `ControlMaster` in the
   user's SSH config, the persistent master process inherits the pipe and can hold the write end
   open after our `ssh` exits. Waiting for EOF alone would hang forever. A 250 ms grace period
   after termination collects the tail and then stops waiting.

### Refresh lifecycle

```
refresh() ──► already in flight? ──yes──► drop
                    │no
                    ▼
            connection = .connecting
            Task { AgentClient.snapshot() }
                    │
        ┌───────────┴───────────┐
     success                 failure
        │                       │
  cache + notify         keep old snapshot,
  reset failure count    mark stale, count++
        │                       │
        └───────────┬───────────┘
                    ▼
            scheduleNextPoll()   ← interval from PollingPolicy
```

A failure never discards data. This is what makes closing the laptop lid and reopening it on a
train produce "here are your jobs, as of 40 minutes ago" instead of an empty window.

## Agent side

### Command budget

The agent's cost is **fixed per refresh**, not proportional to job count:

| Call | Purpose |
| --- | --- |
| `squeue --json` (or `-o` fallback) | The live queue |
| `sacct --allocations` | Recently finished jobs |
| `sacct` (steps) | Peak memory for finished jobs |
| `sstat --allsteps --jobs=a,b,c` | Live memory for *all* running jobs in one call |
| `scontrol show config` | Cluster name + Slurm version (one call gets both) |

`scontrol show job` is **not** in that list. It's the only way to learn a job's `StdOut` path
when `squeue --json` is unavailable, but it costs one controller RPC per job — so it runs only
when the user opens a specific job.

### Parsing strategy

Structured output is always preferred:

1. `squeue --json`, tolerating three generations of field shapes — plain scalars (≤ 20.11),
   `{set, infinite, number}` wrappers (≥ 23.11), and `job_state` as either a string or a list.
2. If that fails, `squeue -o` with a **three-character delimiter** (`|@|`) and free-text fields
   (`nodelist`, `reason`, `name`) placed last, so a `|` inside a job name can't shift any field.
   A single `|` would not be safe.
3. `sacct --parsable2` with `JobName` last, for the same reason.

Human-formatted tables are never parsed, and no parsing depends on column positions.

### Degradation

Nothing outside `squeue` is required. Each missing capability produces a structured warning and
the snapshot still returns, exit code 0:

| Missing | Warning | Lost |
| --- | --- | --- |
| `squeue --json` | `SQUEUE_JSON_UNSUPPORTED` | Log paths during polling |
| `sacct` | `SACCT_UNAVAILABLE` | Finished jobs, exit codes |
| accounting | `ACCOUNTING_DISABLED` | Same |
| `sstat` | `SSTAT_UNAVAILABLE` | Live memory |
| progress dir | `PROGRESS_DIR_MISSING` | Epoch/loss |
| `squeue` | `SLURM_MISSING` (severity `error`) | Everything |

Nonzero exit is reserved for genuinely fatal cases: bad arguments, invalid job id, job not found.

## Progress SDK

Three constraints, in priority order:

1. **Never break the workload.** Every public method catches its own exceptions — including the
   constructor, which is where a bad state directory is discovered. A full disk degrades
   SlurmBar's display; it does not kill a 40-hour run.
2. **Never hammer the filesystem.** Writes are rate-limited to one per 5 s by default. Calling
   `update()` per batch (~1900 times in the bundled example) produces a handful of writes.
   Phase change, completion and failure bypass the limiter, so the interesting moments are never
   lost.
3. **Never let a reader see a torn file.** Write to a sibling temp file, flush, `fsync`, then
   `os.replace` — atomic within a directory on POSIX. The agent either sees the whole previous
   document or the whole new one.

## Testing without a cluster

Every test is fixture-driven. The `fixtures/` directory holds synthetic `squeue`, `sacct`,
`sstat` and log output shaped like supported Slurm versions; `protocol/examples/` holds the JSON
payloads that *both* language test suites decode.

To exercise the built zipapp against realistic Slurm output end-to-end, put stub executables on
`PATH`:

```bash
mkdir -p /tmp/fakeslurm/bin
cat > /tmp/fakeslurm/bin/squeue <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in --json) cat "$REPO/fixtures/squeue/squeue-json-2311.json"; exit 0 ;; esac
done
cat "$REPO/fixtures/squeue/squeue-text.txt"
EOF
chmod +x /tmp/fakeslurm/bin/squeue   # …and sacct, sstat, scontrol

PATH=/tmp/fakeslurm/bin:$PATH python3 out/slurmbar-agent.pyz snapshot --json
```

This is how the JSON path, the text fallback, the merge logic and the real subprocess plumbing
were verified together. Removing `--json` support from the stub exercises the fallback branch.

## Extension points

- **New log parsers**: append to `COUNTER_PATTERNS` or `CUSTOM_PARSERS` in
  `agent/slurmbar_agent/logparse.py`. No protocol change; `source`/`confidence` already carry
  the provenance.
- **New Slurm sources**: add a collector module and merge it in `snapshot.py`.
- **Protocol changes**: bump `SCHEMA_VERSION` in both `agent/slurmbar_agent/protocol.py` and
  `ProtocolDecoder.supportedSchemaVersion`. The app already reports a version mismatch with the
  correct "update which side" advice.
- **New notification kinds**: add a case to `JobEvent.Kind` and a toggle to
  `NotificationPreferences`.
