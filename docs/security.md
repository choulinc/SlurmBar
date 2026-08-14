# Security model

SlurmBar's threat model is simple: it is a desktop app that runs commands on a shared HPC
cluster using the user's own credentials. It must not weaken the user's SSH posture, must not
become a way to run arbitrary things on the cluster, and must not trust what the cluster sends
back.

## Credentials

**SlurmBar never handles SSH keys.** It does not read, store, copy, generate or pass them. It
shells out to `/usr/bin/ssh`, which resolves keys, agents, `IdentityFile`, `ProxyJump` and
`ControlMaster` from the user's own `~/.ssh/config` exactly as it does in Terminal.

**SlurmBar never asks for a password.** Every invocation includes `BatchMode=yes`, which makes
OpenSSH fail rather than prompt. There is no password field anywhere in the app, and there is no
code path that could produce one. If key auth isn't working, the app reports it and tells the
user to run `ssh-add`.

## Host keys

Host key verification is left entirely at OpenSSH's defaults. SlurmBar does **not** pass
`StrictHostKeyChecking=no`, does **not** point `UserKnownHostsFile` at `/dev/null`, and has no
setting that would enable either. A test asserts these strings never appear in the argv.

An unknown host key and a *changed* host key are reported as different errors with different
advice — the first says "verify the fingerprint and connect once in Terminal", the second says
"this can indicate a man-in-the-middle attack; verify out of band". Neither is ever accepted
automatically, and a changed host key is explicitly marked non-transient so the retry loop will
not paper over it.

## Command construction

Two layers, because there are two shells to worry about — and one of them is easy to forget.

**Locally**, `Process` is invoked with an argv array. No local shell is involved, so nothing in
a job id or path can be interpreted by the Mac's shell.

**Remotely**, `ssh host cmd args...` joins its arguments with spaces and hands the result to the
*remote login shell*. That shell does word splitting and expansion. So every remote argument is
single-quoted by `ShellQuoting` before transmission, with embedded single quotes escaped as
`'\''`. The one deliberate exception is a leading `~/`, which stays outside the quotes so the
remote shell expands it — the rest of the path is still quoted.

**Job ids are validated on both sides** against `^\d{1,18}(_\d{1,18})?$` before they can become
an argument. The app validates before sending; the agent validates before use. Neither trusts
the other. Anything else — ranges, step suffixes, whitespace, metacharacters — is rejected.

There is no UI anywhere that runs an arbitrary remote command. The agent command in Settings is
a deliberate exception: it is a path the user types for their own account, equivalent to what
they'd type in Terminal.

## The remote footprint

* No daemon, no supervisor, no systemd unit, no cron entry.
* No listening socket, no port, no inbound connection. The cluster never initiates anything.
* No root, no setuid, no group membership, no write access outside `$HOME`.
* One process per request, lifetime measured in hundreds of milliseconds.
* The installer writes exactly two files (`~/.local/share/slurmbar/slurmbar-agent.pyz` and
  `~/.local/bin/slurmbar-agent`) and modifies no startup file. The uninstaller removes exactly
  those two and leaves job-written progress state alone unless `--purge-progress` is passed.

## What the agent reads

Only:

* output of `squeue`, `sacct`, `sstat`, `scontrol` — i.e. data the user can already see;
* `status.json` inside the configured progress directory, path-checked to be under that
  directory after resolution, capped at 256 KiB, and only for job ids that passed validation;
* a bounded tail of log paths **that Slurm itself reported** for the user's own jobs.

It never walks the home directory, never follows paths supplied by remote data, and never reads
another user's files (it has no privilege to).

## Bounded everything

| Read | Limit |
| --- | --- |
| Log tail window | 128 KiB default, 4 MiB hard cap |
| Log tail lines | 200 default, 2000 hard cap |
| Single log line | 4000 chars |
| Progress `status.json` | 256 KiB |
| Progress metrics | 64 keys, 200 chars per string value |
| Any command's stdout | 8 MiB (agent), 16 MiB (app) |
| Jobs sniffed for log progress per refresh | 12 by default (`--log-fallback-limit`), one read per distinct stream |
| Log paths resolved from the controller per refresh | 6, and only when `squeue` reported none |

Log files on HPC filesystems routinely reach gigabytes. Nothing reads a whole file: the tail
reader seeks to `max(0, size - window)` and reads forward, so cost is bounded by the window.

## Treating remote JSON as untrusted

The agent's output is data from a machine the app doesn't control, so `ProtocolDecoder` gates it
before any model is constructed:

1. **Size** — payloads above 16 MiB are rejected outright.
2. **Schema version** — a version this build doesn't implement is an actionable error, not a
   half-decoded snapshot. The message says which side to update.
3. **Structured errors** — an `error` object in the payload surfaces as the agent's message
   rather than a generic decode failure.
4. **Sanitization** — every string that reaches the UI passes through `SanitizedText`, which
   strips ANSI escape sequences, C0/C1 control characters, `DEL`, and the Unicode bidirectional
   override and isolate codepoints (`U+202A`–`U+202E`, `U+2066`–`U+2069`) used for text-spoofing
   attacks. Lengths are bounded. That is: job names, reasons, user, account, partition, QoS, the
   raw state string, node names, the progress `kind`, metric names and string metric values, log
   lines, warnings and errors.

   Paths (`work_dir`, `stdout_path`, `stderr_path`) are the one exception, and are exempt only
   as *stored* values: they are sent back to the agent to locate a file, and a sanitized path is
   a different path. Each has a sanitized `…Display` counterpart, and that is what the UI
   renders. Where an exact path goes somewhere a control character could still act — the
   `tail -f` snippet the detail view copies to the clipboard — it is shell-quoted.

   Sanitizing can map two distinct metric names onto one; the lexicographically first raw name
   wins, so the same payload always yields the same rows.

This matters because job names are attacker-influenced in the general case: anyone who can
submit a job on the cluster chooses the job name that lands in the popover.

Unknown enum values (a new job state, a new warning code) decode as `UNKNOWN` / pass through
rather than failing, so a newer agent cannot brick an older app.

## Destructive actions

`scancel` is the only destructive operation, and it is guarded three times:

1. It is reachable only from a job's detail view, behind a destructive-styled button.
2. That button opens a confirmation dialog naming the exact job id and job name.
3. The agent itself refuses to run without `--confirm`, which the app passes only after the
   confirmation returns.

No automatic path — polling, refresh, notification handling, startup — can reach it. A test
asserts that a full refresh-and-open-popover cycle never produces a `cancel` invocation.

The test suite never executes `scancel`; only argv construction and the validation guards are
exercised, against a fake runner that records commands without running them.

## Sandboxing

The app is **not** sandboxed. This is a deliberate, documented trade-off: a sandboxed app cannot
execute `/usr/bin/ssh`, cannot read `~/.ssh/config` or `known_hosts`, and cannot reach the SSH
agent socket or `ControlMaster` sockets. Implementing SSH inside the sandbox would mean bundling
an SSH library and reimplementing key handling — which would make SlurmBar responsible for the
user's private keys, exactly what this design avoids.

The consequence is no Mac App Store distribution. For an open-source developer tool that shells
out to the system SSH client, that is the right trade.

## Reporting a vulnerability

Follow the private reporting instructions in the repository's [security policy](../SECURITY.md).
Do not include vulnerability details in a public issue.
