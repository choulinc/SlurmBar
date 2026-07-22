# slurmbar-agent

One-shot Slurm data collector for [SlurmBar](../README.md). Runs on a cluster login node,
gathers Slurm state, prints one JSON document to stdout, exits.

No daemon. No listening port. No root. No third-party dependencies — Python 3.7+ standard
library only.

## Install

From the repository root:

```bash
./scripts/install-agent.sh my-cluster
```

Installs `~/.local/share/slurmbar/slurmbar-agent.pyz` and a launcher at
`~/.local/bin/slurmbar-agent` in your own home directory on the cluster.

## Commands

```bash
slurmbar-agent doctor   --json
slurmbar-agent snapshot --json [--user U] [--history-hours 24] [--progress-dir PATH]
slurmbar-agent job      --json --job-id 201551
slurmbar-agent logs     --json --job-id 201551 --stream stdout --lines 200
slurmbar-agent cancel   --json --job-id 201551 --confirm    # destructive
slurmbar-agent paths    --json
```

JSON goes to stdout; diagnostics go to stderr. Exit 0 means the payload is usable, even when it
carries warnings. See [../docs/protocol.md](../docs/protocol.md).

## Design

* **Fixed command budget.** About five Slurm commands per snapshot regardless of job count —
  nothing is queried per job. `scontrol show job` runs only when the user opens a specific job.
* **Structured output first.** `squeue --json` when available, tolerating field shapes from
  Slurm 20.11 through 23.11+. Otherwise `squeue -o` with a three-character delimiter and
  free-text fields last. Human-formatted tables are never parsed.
* **Degrades instead of failing.** Missing `sacct`, `sstat`, accounting or progress files each
  produce a structured warning; the snapshot still returns.
* **Honest metrics.** Memory values carry their semantics (`peak_rss`, `requested_per_node`, …).
  Anything unavailable is `null`.
* **Bounded reads.** Log tails are capped by bytes and lines; progress files by size.
* **No shell.** Every command is an argv list; `shell=True` appears nowhere.

## Development

```bash
python3 -m venv .venv && .venv/bin/pip install pytest jsonschema
cd agent && ../.venv/bin/python -m pytest tests/ -q
```

307 fixture-driven tests; no Slurm installation required. `scancel` is never executed.
