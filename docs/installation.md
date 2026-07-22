# Installation

## Prerequisites

**On your Mac**
- macOS 14 or later
- Xcode 15+ or a Swift 5.9+ toolchain (`swift --version`)
- Working SSH access to the cluster: `ssh my-cluster true` must succeed **without prompting**

**On the cluster**
- Python 3.7 or newer on `PATH` for non-interactive SSH sessions
- Slurm client commands — `squeue` at minimum

Nothing else. No root, no admin request, no `slurmrestd`, no accounting.

### Verifying the prerequisite that actually matters

```bash
ssh -o BatchMode=yes my-cluster 'python3 --version; command -v squeue'
```

If this prints a Python version and a path to `squeue`, you are ready. If it hangs or asks for
anything, fix that first — SlurmBar runs `ssh` the same way and will not prompt on your behalf.

A common surprise: `PATH` in a **non-interactive** SSH session is often shorter than in a login
shell, because `.bashrc` may exit early for non-interactive shells. If `squeue` is found
interactively but not by the command above, that is the cause. Use an absolute path in the
agent command, or move the module-load into `~/.ssh/environment` (if `PermitUserEnvironment` is
enabled).

## 1. Install the remote agent

```bash
git clone https://github.com/choulinc/SlurmBar.git
cd SlurmBar
./scripts/install-agent.sh my-cluster
```

The script:

1. builds `out/slurmbar-agent.pyz` locally (a ~44 KB Python zipapp, stdlib only);
2. verifies it can reach `my-cluster` without a prompt;
3. verifies remote Python and prints its version;
4. creates `~/.local/share/slurmbar/` and `~/.local/bin/` in your home directory on the cluster;
5. copies the `.pyz` there via `scp` (falling back to piping over `ssh`);
6. writes a launcher at `~/.local/bin/slurmbar-agent`;
7. runs `doctor` and prints a readable report.

It does **not** use `sudo`, write outside your home directory, or modify `.bashrc`, `.zshrc`,
`.profile` or any other startup file.

### If Python is somewhere unusual

```bash
./scripts/install-agent.sh my-cluster --python /opt/python/3.11/bin/python3
```

The launcher and the suggested agent command both use the path you give.

### If `~/.local/bin` is not on your PATH

It doesn't matter. SlurmBar always invokes the `.pyz` by its full path and never relies on
`PATH`. The launcher is a convenience for running it by hand. To use it interactively either
add the directory to your `PATH` yourself, or just call the full path:

```bash
python3 ~/.local/share/slurmbar/slurmbar-agent.pyz doctor --json
```

### Manual installation

If you prefer not to run the script:

```bash
./scripts/build-agent-zipapp.sh
ssh my-cluster 'mkdir -p ~/.local/share/slurmbar'
scp out/slurmbar-agent.pyz my-cluster:.local/share/slurmbar/
ssh my-cluster 'python3 ~/.local/share/slurmbar/slurmbar-agent.pyz doctor --json'
```

## 2. Build the Mac app

```bash
./scripts/build-macos-app.sh
open out/SlurmBar.app
```

This builds in release configuration, assembles a proper `.app` bundle (needed for menu bar
placement, notifications and launch-at-login), and ad-hoc signs it.

In Xcode instead:

```bash
xed app/
```

Then select the `SlurmBar` scheme and run. Note that running the bare SwiftPM executable works
for development, but notifications and launch-at-login require the bundle.

### Installing it properly

```bash
cp -R out/SlurmBar.app /Applications/
```

`SMAppService` (Launch at Login) requires the app to live in `/Applications`.

## 3. Add the cluster in SlurmBar

SlurmBar has no Dock icon — look for the server icon in the menu bar. Open **Settings →
Clusters → +** and fill in:

| Field | Value | Notes |
| --- | --- | --- |
| Display name | `My Cluster` | Free text, shown in the UI. |
| SSH alias | `my-cluster` | A `Host` entry from `~/.ssh/config`, or `user@host`. |
| Agent command | `python3 ~/.local/share/slurmbar/slurmbar-agent.pyz` | Exactly what `install-agent.sh` printed. |
| Username override | *(empty)* | Only if it differs from your SSH config. |
| Slurm user | *(empty)* | Defaults to the SSH user. |
| Progress directory | *(empty)* | Defaults to `~/.local/state/slurmbar/jobs`. |
| Polling interval | `30` s | Background cadence; the app adapts around it. |

Click **Test Connection**. You should see a list of checks, most `ok`. Warnings on
`squeue --json`, `sacct` or the progress directory are normal on many clusters and don't prevent
use.

Then click **Save**.

## 4. Recommended SSH configuration

```sshconfig
Host my-cluster
    HostName login.example.org
    User exampleuser
    IdentityFile ~/.ssh/id_ed25519

    # Strongly recommended: reuse one connection across polls, so each refresh is a
    # multiplexed channel instead of a fresh TCP + auth handshake.
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m

    # Through a bastion:
    # ProxyJump bastion.example.org
```

`ControlPersist 10m` pairs well with a 30 s polling interval: the connection stays warm between
polls and closes on its own when you stop using it.

## 5. Add progress reporting to a workload (optional)

Slurm knows a job is `RUNNING`; it does not know it is on epoch 375 of 1000. To see that, the
workload has to say so.

Install the SDK on the cluster — it is pure standard library, so copying the directory is enough:

```bash
scp -r progress/slurmbar_progress my-cluster:~/my-project/
# or:
ssh my-cluster 'pip install --user /path/to/SlurmBar/progress'
```

Then in your training script:

```python
from slurmbar_progress import ProgressReporter

with ProgressReporter(kind="training") as reporter:
    for epoch in range(total_epochs):
        loss = train_one_epoch()
        reporter.update(current=epoch + 1, total=total_epochs, unit="epoch",
                        phase="train", metrics={"loss": float(loss)})
```

Submit the job. Within one polling interval the row will show an epoch counter, a progress bar,
a percentage, loss and an ETA.

To verify without submitting anything:

```bash
python3 progress/examples/training_loop.py     # prints the status.json path it writes
python3 out/slurmbar-agent.pyz snapshot --json --progress-dir ~/.local/state/slurmbar/jobs
```

## Upgrading

```bash
git pull
./scripts/install-agent.sh my-cluster    # replaces the .pyz in place
./scripts/build-macos-app.sh
```

If the two sides ever disagree on protocol version, SlurmBar says so explicitly and tells you
which side to update rather than showing wrong data.

## Uninstalling

```bash
./scripts/uninstall-agent.sh my-cluster              # removes the two installed files
./scripts/uninstall-agent.sh my-cluster --purge-progress   # also removes job progress state
rm -rf /Applications/SlurmBar.app
rm -rf ~/Library/Application\ Support/SlurmBar       # settings
rm -rf ~/Library/Caches/SlurmBar                     # cached snapshots
```
