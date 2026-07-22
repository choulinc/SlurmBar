# Troubleshooting

SlurmBar tries hard to never say "Unknown error". Every failure below maps to a specific
message with a specific suggested fix, both in the popover and here.

## First: reproduce it in Terminal

Almost every connection problem reproduces with one command. SlurmBar's "Copy Command" action in
the job detail view gives you the exact invocation, but the short version is:

```bash
ssh -o BatchMode=yes my-cluster 'python3 ~/.local/share/slurmbar/slurmbar-agent.pyz doctor --json'
```

If that works and SlurmBar doesn't, the problem is in the app's configuration (usually the agent
command). If it fails the same way, the message tells you what to fix.

## Connection errors

### "SSH host not found"
`ssh` could not resolve the alias. It isn't in `~/.ssh/config`, or it's misspelled in Settings.

```bash
ssh my-cluster true          # should succeed silently
grep -A5 'Host my-cluster' ~/.ssh/config
```

### "Cluster unreachable" / "Connection timed out"
The login node did not answer. Usually a VPN that has dropped, or a laptop that just woke up.

SlurmBar keeps showing your last snapshot, clearly marked stale, and backs off exponentially
(30 s → 60 s → 120 s …, capped at 10 minutes) so it isn't hammering a network that isn't there.
Reconnect the VPN and click **Retry**.

### "Authentication failed"
The cluster rejected your key. SlurmBar runs with `BatchMode=yes` and will never prompt for a
password — this is by design.

```bash
ssh-add -l                        # is your key loaded?
ssh-add ~/.ssh/id_ed25519         # load it
ssh -v my-cluster true 2>&1 | grep -i 'offering\|denied'
```

If your key has a passphrase, unlock it once in Terminal; the agent keeps it for the session.

### "Interactive login required"
The cluster wants an OTP, a password, or another keyboard-interactive step. SlurmBar runs `ssh`
with `BatchMode=yes` and can never answer such a prompt — by design, so it cannot be tricked
into collecting your credentials.

```bash
ssh my-cluster           # complete the interactive login here, once
ssh -O check my-cluster  # should print "Master running"
```

With `ControlMaster auto` / `ControlPersist` in your `~/.ssh/config`, SlurmBar then reuses that
connection. Verify the reuse actually works non-interactively:

```bash
ssh -o BatchMode=yes my-cluster true && echo "SlurmBar can connect"
```

If that succeeds but a fresh connection fails, everything is working as intended — just raise
`ControlPersist` so the master outlives your idle periods.

### "Unknown host key"
The cluster's host key isn't in `~/.ssh/known_hosts`. SlurmBar will not accept an unknown key on
your behalf. Connect once in Terminal, verify the fingerprint against what your site publishes,
and accept it there.

```bash
ssh my-cluster
```

### "Host key changed"
Different, and more serious. The key doesn't match what's stored. This happens legitimately when
a login node is rebuilt — and illegitimately during a man-in-the-middle attack. **Verify the new
fingerprint out of band** (your site's documentation, a colleague, a support ticket) before
changing anything. SlurmBar marks this failure non-transient so it won't quietly retry past it.

## Remote errors

### "Agent not installed"
The `.pyz` isn't where the agent command says it is.

```bash
ssh my-cluster 'ls -la ~/.local/share/slurmbar/'
./scripts/install-agent.sh my-cluster       # reinstall
```

Also check the **Agent command** field in Settings matches the path the installer printed.

### "Python not found on the cluster"
`python3` isn't on `PATH` in a non-interactive SSH session.

```bash
ssh my-cluster 'command -v python3'                    # what SlurmBar sees
ssh my-cluster -t 'command -v python3'                 # what you see interactively
```

If the second works and the first doesn't, your `.bashrc` is exiting early for non-interactive
shells (a very common default). Fix it by putting an absolute path in the agent command:

```
/opt/python/3.11/bin/python3 ~/.local/share/slurmbar/slurmbar-agent.pyz
```

### "The agent's response was not valid JSON"
Something printed to stdout before the JSON — nearly always a shell startup file echoing a
banner, a MOTD, or a `module load` message.

```bash
ssh my-cluster true            # must print absolutely nothing
```

Whatever it prints is the culprit. Guard it in your shell config:

```bash
# ~/.bashrc — only print banners for interactive shells
case $- in *i*) echo "Welcome!" ;; esac
```

### "protocol v0 / v2; this version speaks v1"
The app and agent are from different releases. The message says which side to update. Usually:

```bash
./scripts/install-agent.sh my-cluster
```

## Missing data

### No recently finished jobs
Slurm accounting (`slurmdbd`) isn't available. The popover shows a `SACCT_UNAVAILABLE` or
`ACCOUNTING_DISABLED` warning. Running and pending jobs work normally; exit codes and finished-job
memory don't. This is a site configuration matter, not something SlurmBar can work around.

```bash
ssh my-cluster 'sacct -X --starttime=now-1hours'
```

### Memory shows N/A
Expected in several normal situations:

- **Running job, no live memory**: `sstat` only reports while a job *step* is active. A job
  whose payload runs directly in the batch script without `srun` may never register one.
- **Finished job, no peak memory**: requires accounting with job-step records.
- **No requested memory**: the job didn't specify `--mem`.

SlurmBar shows `N/A` rather than substituting a plausible number.

### Memory looks too low
It probably isn't wrong — read the label. `112.6 GB peak` is `MaxRSS`: the high-water mark of
the *largest single step*, not the sum across nodes and not the current value. For a multi-node
job, per-node peaks are not summed, because summing peaks that occurred at different times would
be meaningless.

### GPU memory / utilization always N/A
Slurm only reports these if your site's accounting records `gres/gpumem` and `gres/gpuutil`.
Most sites don't. SlurmBar deliberately does **not** run `nvidia-smi` through a new `srun` step
to fill the gap: that perturbs the allocation and costs a scheduler RPC per refresh.

If you need GPU memory, report it yourself from inside the job:

```python
reporter.update(metrics={"gpu_mem_gb": torch.cuda.max_memory_allocated() / 2**30})
```

### No epoch, batch or loss
Expected. Slurm has no idea what your process is doing. Add `slurmbar_progress` (three lines) or
rely on the log-parser fallback, which is labelled **guessed** in the UI.

### Progress shows "guessed"
That row's numbers came from parsing your log's tail, not from the workload. It's a best-effort
pattern match, never produces an ETA, and is superseded the moment structured progress appears.

### Progress marked "stale"
The workload stopped calling `update()`. Common causes: the process is stuck, it crashed without
using the context manager, or it's in a long phase that doesn't report. The last known values
stay visible, dimmed, so you can see *where* it stopped.

Use the context manager so a crash records itself:

```python
with ProgressReporter(kind="training") as reporter:
    ...   # a raised exception marks the job failed, with the exception text
```

### Progress never appears at all
Check the agent and the workload agree on the directory:

```bash
ssh my-cluster 'ls -la ~/.local/state/slurmbar/jobs/'
ssh my-cluster 'python3 ~/.local/share/slurmbar/slurmbar-agent.pyz paths'
```

If your job writes to a different filesystem (a scratch path exported via `SLURMBAR_STATE_DIR`),
set the same path in SlurmBar's **Progress directory** setting. The directory must be readable
from the **login node**, not just from the compute node — a node-local `/tmp` will not work.

### A job disappeared
Jobs leave `squeue` when they finish and appear in `sacct`. If accounting is unavailable, a
finished job simply vanishes. Increase **Job history** in Settings to see further back.

## App behaviour

### The menu bar item is missing
SlurmBar has no Dock icon (`LSUIElement`). If the icon isn't in the menu bar, check the process:

```bash
pgrep -x SlurmBar
```

A very full menu bar can hide items — macOS drops items that don't fit, especially on notched
displays.

### Launch at Login does nothing
`SMAppService` requires the app to be in `/Applications` and signed:

```bash
cp -R out/SlurmBar.app /Applications/
codesign -dv /Applications/SlurmBar.app
```

### No notifications
Check System Settings → Notifications → SlurmBar. The permission prompt appears on first launch
of the bundled app; a bare SwiftPM binary can't request it.

Also note notifications are **edge-triggered**: they fire on a transition, never on a state that
was already true. The first refresh after launch establishes a silent baseline on purpose, so
restarting doesn't replay yesterday's finished jobs.

### It feels slow to update
By design. Default cadence is ~12 s with the popover open, 30 s closed, ~75 s when nothing is
active. A Slurm controller serves the whole cluster, and a menu bar app polling it aggressively
is a real problem. Use the refresh button when you want an immediate answer.

## Resetting

```bash
rm -rf ~/Library/Application\ Support/SlurmBar   # settings (clusters, preferences)
rm -rf ~/Library/Caches/SlurmBar                 # cached snapshots
```

A settings file that can't be parsed is never destroyed — it's copied to `settings.corrupt.json`
next to the original so hand edits are recoverable.

## Reporting a bug

Include:

```bash
sw_vers
swift --version
ssh -V
ssh my-cluster 'python3 ~/.local/share/slurmbar/slurmbar-agent.pyz doctor --json'
ssh my-cluster 'sinfo --version'
```

Redact hostnames and usernames — SlurmBar's own fixtures and docs contain none.
