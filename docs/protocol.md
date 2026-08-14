# Protocol

Full JSON Schema in [`../protocol/schema/`](../protocol/schema/); example payloads in
[`../protocol/examples/`](../protocol/examples/). Those examples are decoded by **both** the
Python and the Swift test suites, so the two implementations cannot drift apart silently.

Current version: **`schema_version: 1`**.

## Commands

| Command | Response | Called |
| --- | --- | --- |
| `slurmbar-agent snapshot --json` | `snapshot.schema.json` | Every poll |
| `slurmbar-agent doctor --json` | `doctor.schema.json` | Test Connection |
| `slurmbar-agent job --job-id ID --json` | job detail | Opening a job |
| `slurmbar-agent logs --job-id ID --stream stdout --lines 200 --json` | `logs.schema.json` | Viewing logs |
| `slurmbar-agent cancel --job-id ID --confirm --json` | `cancel.schema.json` | Confirmed cancel only |
| `slurmbar-agent paths --json` | diagnostic | Manual |

Optional flags on `snapshot`: `--user`, `--history-hours`, `--progress-dir`,
`--progress-stale-seconds`, `--no-log-fallback`, `--no-sstat`.

## Conventions

These are enforced by tests on both sides.

| Rule | Why |
| --- | --- |
| Timestamps are UTC ISO 8601 with `Z` | Slurm emits timezone-naive local time; only the login node knows the zone, so it converts. |
| Durations are integer seconds | No unit ambiguity, no float drift. |
| Byte counts are integers | Same. |
| Percentages are `0…100` numbers | Not `0…1`, not strings. |
| `null` means "not available" | Never `0`, never `-1`, never a placeholder. The UI renders `N/A`. |
| Unknown enum values are tolerated | A newer agent must not brick an older app. |
| Warnings are structured | `code` + `severity` lets the UI distinguish causes instead of one error bucket. |
| Partial data + warnings, exit 0 | Nonzero exit is reserved for genuinely unusable output. |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Usable payload on stdout — possibly with warnings. |
| `1` | Internal error. |
| `2` | Invalid argument (bad job id, bad user, missing `--confirm`). |
| `3` | Slurm unavailable. |
| `4` | Job not found. |
| `5` | Permission denied. |

On any nonzero exit, stdout still carries `{"error": {"code": …, "message": …}}` so the app can
show the real reason.

## Normalized job states

`PENDING` · `RUNNING` · `SUSPENDED` · `COMPLETING` · `COMPLETED` · `FAILED` · `CANCELLED` ·
`TIMEOUT` · `OUT_OF_MEMORY` · `NODE_FAIL` · `PREEMPTED` · `BOOT_FAIL` · `DEADLINE` · `REQUEUED` ·
`UNKNOWN`

`slurm_job_id` carries the id Slurm uses internally. For an array task it differs from
`job_id` (`123_4` may be `slurm_job_id` `127`), and it is what `sstat` answers with — matching
only on the display id gives every task in an array the array parent's memory figure.

`state_raw` always carries exactly what Slurm said (`"R"`, `"CANCELLED by 100234"`,
`"OUT_OF_ME+"`), so nothing is lost in normalization. Anything unrecognized maps to `UNKNOWN`
with the raw text preserved — never silently misfiled into a neighbouring state.

## Memory semantics

The field that keeps SlurmBar honest. Both `memory_semantics` (for the used value) and
`memory_limit_semantics` (for the limit) travel with their numbers:

| Value | Meaning |
| --- | --- |
| `peak_rss` | Highest RSS seen for a running step so far (`sstat MaxRSS`). Not the live total. |
| `peak_rss_per_step` | Highest RSS of the largest single step (`sacct MaxRSS`). Not summed across nodes. |
| `current_rss` | RSS at measurement time. |
| `requested_total` | Requested for the whole job. |
| `requested_per_node` | Requested **per node** — multiply by node count for the job total. |
| `requested_per_cpu` | Requested **per CPU** — multiply by CPU count. |
| `unavailable` | Not reported. The value is `null`. |

The app only draws a usage bar when the two values are genuinely comparable (`requested_total`
or `requested_per_node`). For a per-CPU request it shows both numbers with their labels and no
bar, because filling a bar against a per-CPU figure would be a lie.

## Progress provenance

| `source` | `confidence` | Meaning |
| --- | --- | --- |
| `structured_file` | `high` | The workload reported it via `slurmbar_progress`. Authoritative; the only source that can yield an ETA. |
| `log_parser` | `medium` / `low` | Inferred from the tail of the job's stdout or stderr, whichever carries the more confident reading. Labelled **guessed** in the UI; never produces an ETA. |

`stale: true` means the workload has stopped updating. The last values remain visible (dimmed),
and no ETA is derived from a stale sample.

`total: null` is legitimate — a preprocessing job that doesn't know how many files it will
process reports a counter with no total, and the UI shows "4,820 files" with no progress bar
rather than a fabricated percentage.

Metrics are free-form. NaN and infinity travel as the strings `"nan"`, `"inf"`, `"-inf"`,
because JSON cannot represent them and a NaN loss is exactly the kind of thing worth notifying
about.

## Warning codes

| Code | Severity | Consequence |
| --- | --- | --- |
| `SLURM_MISSING` | error | No jobs at all. |
| `SQUEUE_FAILED` | error | Queue unreadable. |
| `SQUEUE_JSON_UNSUPPORTED` | info | Text fallback in use; log paths unavailable while polling. |
| `SQUEUE_TEXT_UNPARSABLE` | warning | One line skipped; the rest are fine. |
| `SACCT_UNAVAILABLE` / `SACCT_FAILED` / `ACCOUNTING_DISABLED` | info/warning | No finished jobs, no exit codes. |
| `SSTAT_UNAVAILABLE` / `SSTAT_FAILED` | info | No live memory. Very common and benign. |
| `MEMORY_UNAVAILABLE` | info | No step-level memory. |
| `GPU_METRICS_UNAVAILABLE` | info | Site accounting doesn't record GPU TRES. |
| `PROGRESS_DIR_MISSING` | info | No structured progress anywhere. |
| `PROGRESS_FILE_INVALID` / `PROGRESS_SCHEMA_UNSUPPORTED` | warning | That job's progress ignored. |
| `PROGRESS_STALE` | info | Workload stopped updating. |
| `LOG_PATH_UNKNOWN` / `LOG_UNREADABLE` | info | No log tail for that job. |
| `COMMAND_TIMEOUT` / `COMMAND_FAILED` | warning/error | A Slurm command didn't complete. |
| `PARTIAL_DATA` | warning | Some records were skipped. |

Consumers must tolerate codes they don't recognize.

## Progress status file

Written by `slurmbar_progress` to `<state_dir>/<job_id>/status.json`, read by the agent. Schema:
`progress-status.schema.json`.

`<job_id>` is what `squeue` displays — `123` normally, `123_4` for an array task. The agent looks
for the exact id first, then falls back to the array parent, so a reporter that only saw
`SLURM_ARRAY_JOB_ID` still gets matched.

Writes are atomic (temp file in the same directory → `fsync` → `os.replace`), so a reader
concurrent with a write sees either the whole previous document or the whole new one.

## Changing the protocol

1. Bump `SCHEMA_VERSION` in `agent/slurmbar_agent/protocol.py`.
2. Bump `ProtocolDecoder.supportedSchemaVersion` in the Swift package.
3. Update `protocol/schema/*.json` and the examples.
4. Run both suites — the shared examples will catch anything that only one side implements.

Additive changes (a new optional field, a new enum value, a new warning code) do **not** need a
version bump: both sides ignore unknown fields and degrade unknown enums gracefully. Reserve the
bump for changes that would make an older consumer show *wrong* data.
