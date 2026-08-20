#!/usr/bin/env python3
"""Generate a deliberately fictional snapshot for documentation screenshots.

Times are computed relative to now so elapsed values always look plausible, whenever the
screenshot is taken. Every identifier, path, resource value and metric is synthetic. The
``.invalid`` hostname and ``demo-*`` names make that visible in the screenshots too.

    python3 demo/make-demo-snapshot.py > demo/snapshot.json
"""
import datetime as dt, json, sys

UTC = dt.timezone.utc
now = dt.datetime.now(UTC).replace(microsecond=0)
def ago(**kw): return (now - dt.timedelta(**kw)).strftime("%Y-%m-%dT%H:%M:%SZ")
def secs(**kw): return int(dt.timedelta(**kw).total_seconds())
GiB = 1024 ** 3

def res(used=None, limit=None, sem="unavailable", lim_sem="unavailable",
        gmem=None, gutil=None):
    # Byte counts are integers in the protocol; Swift decodes them as Int64, so a float here
    # would fail to decode in the app even though Python is happy to emit it.
    ints = lambda v: None if v is None else int(v)
    used, limit, gmem = ints(used), ints(limit), ints(gmem)
    return {"memory_used_bytes": used, "memory_limit_bytes": limit,
            "memory_semantics": sem, "memory_limit_semantics": lim_sem,
            "gpu_memory_used_bytes": gmem, "gpu_memory_limit_bytes": None,
            "gpu_utilization_percent": gutil, "cpu_utilization_percent": None}

def prog(source="structured_file", **kw):
    base = {"source": source, "confidence": "high" if source == "structured_file" else "medium",
            "kind": None, "phase": None, "current": None, "total": None, "unit": None,
            "percent": None, "message": None, "updated_at": ago(seconds=8),
            "started_at": None, "stale": False, "eta_seconds": None,
            "completion": "running", "error": None, "metrics": {}}
    base.update(kw)
    return base

def job(**kw):
    base = {"job_id": "", "slurm_job_id": None, "array_job_id": None, "array_task_id": None,
            "name": "", "user": "demo-user", "account": "demo-account", "partition": "accelerated",
            "qos": "normal", "state": "RUNNING", "state_raw": None, "reason": None,
            "submit_time": None, "start_time": None, "end_time": None,
            "elapsed_seconds": None, "time_limit_seconds": None, "nodes": [], "node_count": 1,
            "cpus": None, "gpus": None, "work_dir": None, "stdout_path": None,
            "stderr_path": None, "exit_code": None, "signal": None, "source": "squeue",
            "resources": res(), "progress": None}
    base.update(kw)
    if base["state_raw"] is None:
        base["state_raw"] = base["state"]
    return base

jobs = [
    # The headline: real training progress with everything populated.
    job(job_id="10001", name="demo-training", state="RUNNING", partition="accelerated",
        submit_time=ago(hours=9, minutes=5), start_time=ago(hours=9),
        elapsed_seconds=secs(hours=9), time_limit_seconds=secs(hours=24),
        nodes=["demo-accelerator-01"], cpus=8, gpus=1,
        stdout_path="/home/demo-user/slurmbar-demo/logs/demo-training-10001.out",
        resources=res(12 * GiB, 32 * GiB, "peak_rss", "requested_total",
                      gmem=8 * GiB, gutil=72),
        progress=prog(kind="training", phase="train", current=42, total=100, unit="epoch",
                      percent=42.0, eta_seconds=secs(hours=2, minutes=15),
                      metrics={"loss": 0.1234, "learning_rate": 1e-04,
                               "batch_current": 10, "batch_total": 25, "score": 0.8123})),

    # A second training run, counted in steps rather than epochs.
    job(job_id="10002", name="demo-finetune", state="RUNNING", partition="accelerated",
        submit_time=ago(hours=3, minutes=20), start_time=ago(hours=3, minutes=12),
        elapsed_seconds=secs(hours=3, minutes=12), time_limit_seconds=secs(hours=48),
        nodes=["demo-accelerator-02", "demo-accelerator-03"], node_count=2, cpus=16, gpus=2,
        resources=res(24 * GiB, 64 * GiB, "peak_rss", "requested_total",
                      gmem=16 * GiB, gutil=68),
        progress=prog(kind="training", phase="train", current=250, total=1000, unit="step",
                      percent=25.0, eta_seconds=secs(hours=3),
                      metrics={"loss": 0.987, "learning_rate": 5e-05, "grad_norm": 0.75})),

    # Total unknown: shows a counter with no bar and no invented percentage.
    job(job_id="10003", name="demo-preprocess", state="RUNNING", partition="standard",
        submit_time=ago(hours=1, minutes=40), start_time=ago(hours=1, minutes=38),
        elapsed_seconds=secs(hours=1, minutes=38), time_limit_seconds=None,
        nodes=["demo-compute-01"], cpus=8,
        resources=res(6 * GiB, 16 * GiB, "peak_rss", "requested_total"),
        progress=prog(kind="preprocessing", phase="convert", current=480, total=None,
                      unit="file", message="Converting example files")),

    # Progress guessed from the log: shows the "guessed" badge and no ETA.
    job(job_id="10004", name="demo-simulation", state="RUNNING", partition="standard",
        submit_time=ago(minutes=52), start_time=ago(minutes=50),
        elapsed_seconds=secs(minutes=50), time_limit_seconds=secs(hours=12),
        nodes=["demo-compute-02"], cpus=4,
        resources=res(limit=8 * GiB, lim_sem="requested_total"),
        progress=prog(source="log_parser", kind=None, current=300, total=1000,
                      unit="step", percent=30.0, completion=None,
                      metrics={"residual": 2.5e-04})),

    # Pending array task with a real scheduler reason.
    job(job_id="10010_3", slurm_job_id="10013", array_job_id="10010", array_task_id="3",
        name="demo-array-task", state="PENDING", partition="accelerated",
        reason="Resources", submit_time=ago(minutes=26), elapsed_seconds=0,
        time_limit_seconds=secs(hours=4), cpus=8, gpus=1,
        resources=res(limit=32 * GiB, lim_sem="requested_total")),

    job(job_id="10020", name="demo-evaluation", state="PENDING", partition="accelerated",
        reason="QOSMaxJobsPerUserLimit", submit_time=ago(minutes=11), elapsed_seconds=0,
        time_limit_seconds=secs(hours=1), cpus=4, gpus=1),

    # Finished: a clean run, an OOM, and a cancellation.
    job(job_id="10030", name="demo-completed", state="COMPLETED", partition="accelerated",
        submit_time=ago(hours=22), start_time=ago(hours=21, minutes=55),
        end_time=ago(hours=2, minutes=10), elapsed_seconds=secs(hours=19, minutes=45),
        time_limit_seconds=secs(hours=24), nodes=["demo-accelerator-01"], cpus=8, gpus=1,
        exit_code=0, signal=0, source="sacct",
        resources=res(10 * GiB, 32 * GiB, "peak_rss_per_step", "requested_total"),
        progress=prog(kind="training", current=100, total=100, unit="epoch", percent=100.0,
                      completion="completed", message="Example run completed",
                      updated_at=ago(hours=2, minutes=10), metrics={"loss": 0.1111})),

    # Early stopping. The counter never reaches 300, and only the workload's own
    # completion="completed" makes this a finished run rather than a truncated one. Slurm sees
    # exit 0 either way. The bar fills because the workload said the work was done.
    job(job_id="10033", name="demo-early-stop", state="COMPLETED", partition="accelerated",
        submit_time=ago(hours=14), start_time=ago(hours=13, minutes=50),
        end_time=ago(hours=4), elapsed_seconds=secs(hours=9, minutes=50),
        time_limit_seconds=secs(hours=24), nodes=["demo-accelerator-02"], cpus=8, gpus=1,
        exit_code=0, signal=0, source="sacct",
        resources=res(9 * GiB, 32 * GiB, "peak_rss_per_step", "requested_total"),
        progress=prog(kind="training", current=284, total=300, unit="epoch",
                      percent=94.6667, completion="completed",
                      message="Early stopping: no improvement in 20 epochs",
                      updated_at=ago(hours=4), metrics={"loss": 0.0412, "val_loss": 0.0533})),

    # The ambiguous one, and the reason the bar is dropped rather than filled: a clean exit
    # with the counter short of the total. Indistinguishable from a run whose final progress
    # update was never written.
    job(job_id="10034", name="demo-short-counter", state="COMPLETED", partition="accelerated",
        submit_time=ago(hours=8), start_time=ago(hours=7, minutes=52),
        end_time=ago(hours=1, minutes=5), elapsed_seconds=secs(hours=6, minutes=47),
        time_limit_seconds=secs(hours=12), nodes=["demo-accelerator-05"], cpus=8, gpus=1,
        exit_code=0, signal=0, source="sacct",
        resources=res(7 * GiB, 32 * GiB, "peak_rss_per_step", "requested_total"),
        progress=prog(source="log_parser", kind=None, current=652, total=1000, unit="epoch",
                      percent=65.2, completion=None, updated_at=ago(hours=1, minutes=5),
                      carried_forward=True, metrics={"loss": 0.2087})),

    job(job_id="10031", name="demo-memory-test", state="OUT_OF_MEMORY", partition="accelerated",
        submit_time=ago(hours=6), start_time=ago(hours=5, minutes=50),
        end_time=ago(hours=5, minutes=12), elapsed_seconds=secs(minutes=38),
        time_limit_seconds=secs(hours=12), nodes=["demo-accelerator-03"], cpus=8, gpus=1,
        exit_code=0, signal=125, source="sacct",
        resources=res(31 * GiB, 32 * GiB, "peak_rss_per_step", "requested_total"),
        progress=prog(kind="training", current=10, total=100, unit="epoch", percent=10.0,
                      completion="failed", error="Example workload exceeded its memory limit",
                      updated_at=ago(hours=5, minutes=12), metrics={"loss": 1.23})),

    job(job_id="10032", name="demo-cancelled", state="CANCELLED",
        state_raw="CANCELLED by 99999", partition="accelerated",
        submit_time=ago(hours=23), start_time=ago(hours=23), end_time=ago(hours=22, minutes=48),
        elapsed_seconds=secs(minutes=12), time_limit_seconds=secs(minutes=30),
        nodes=["demo-accelerator-04"], cpus=4, gpus=1, exit_code=0, signal=0, source="sacct"),
]

snapshot = {
    "schema_version": 1,
    "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "agent_version": "0.2.5",
    "cluster": {"name": "demo-cluster", "hostname": "login.demo.invalid",
                "slurm_version": "slurm 24.05.0-demo"},
    # Must match what the jobs above actually are: the app recomputes these from the visible
    # list, so a demo payload that disagrees would render inconsistently on purpose.
    "summary": {"running": 4, "pending": 2, "completing": 0,
                "failed_recently": 1, "cancelled_recently": 1, "completed_recently": 3},
    "jobs": jobs,
    "warnings": [],
}
json.dump(snapshot, sys.stdout, indent=2)
sys.stdout.write("\n")
