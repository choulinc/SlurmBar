# SlurmBar wire protocol

The macOS app and the remote Python agent share one versioned JSON protocol. Everything the
app renders comes through it; the app never parses Slurm output itself.

| File | Produced by | Consumed by |
| --- | --- | --- |
| `schema/snapshot.schema.json` | `slurmbar-agent snapshot --json` | `SlurmBarKit.Snapshot` |
| `schema/doctor.schema.json` | `slurmbar-agent doctor --json` | `SlurmBarKit.DoctorReport` |
| `schema/logs.schema.json` | `slurmbar-agent logs --json` | `SlurmBarKit.LogTail` |
| `schema/gpu.schema.json` | `slurmbar-agent gpu --json` | `SlurmBarKit.GPUStatusResponse` |
| `schema/cancel.schema.json` | `slurmbar-agent cancel --json` | `SlurmBarKit.CancelResult` |
| `schema/progress-status.schema.json` | `slurmbar_progress` inside the job | `slurmbar-agent` on the login node |

## Rules

1. **`schema_version` is an integer.** It is currently `1`. The app refuses to decode a payload
   whose `schema_version` it does not implement and reports it as an actionable error rather
   than silently showing wrong data.
2. **Timestamps are UTC ISO 8601 with a trailing `Z`** (`2026-07-22T02:30:00Z`). The agent runs on
   the login node, so it — not the Mac — converts Slurm's timezone-naive local timestamps.
3. **Durations are integer seconds. Byte counts are integers. Percentages are `0…100`.**
4. **`null` means "not available".** Neither side ever substitutes a placeholder number. The UI
   renders `N/A`.
5. **Memory numbers always travel with their semantics** (`memory_semantics`,
   `memory_limit_semantics`). `MaxRSS` is a peak, not live usage; a request may be per node or
   per CPU. The UI shows the semantics next to the value.
6. **Unknown enum values are tolerated, not fatal.** New normalized states or warning codes
   decode as `UNKNOWN` / are passed through, so an older app keeps working against a newer agent.
7. **Warnings are structured** (`code`, `message`, `severity`, optional `detail`/`job_id`), so the
   UI can distinguish "accounting disabled" from "SSH failed" instead of showing "Unknown error".
8. **Partial results beat no results.** If `sacct` is unavailable the agent still returns `squeue`
   jobs plus a `SACCT_UNAVAILABLE` warning and exits `0`. Nonzero exit is reserved for fatal
   errors (bad arguments, no Slurm at all, unreadable request).

## Progress provenance

`progress.source` is the single most important honesty field in the protocol.

- `structured_file` — written by `slurmbar_progress` inside the workload. Authoritative.
  `confidence` is `high`.
- `log_parser` — inferred from the tail of the job's stdout. Best effort, `confidence` is
  `medium` or `low`, and the UI labels it as guessed.

Slurm itself knows nothing about epochs, batches or loss. Any such value in a snapshot came from
one of those two sources and is labelled accordingly.

## Examples

`examples/` holds byte-exact payloads used by both the Python and Swift test suites, so a change
in one language that breaks the other is caught immediately.
