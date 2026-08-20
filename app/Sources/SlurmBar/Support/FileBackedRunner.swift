import Foundation
import SlurmBarKit

/// Serves canned agent responses from disk instead of running `ssh`.
///
/// Only reachable when `SLURMBAR_DEMO_SNAPSHOT` is set. It exists so documentation screenshots
/// can be taken without exposing real job names, account names or cluster paths — and so the
/// UI can be exercised on a machine with no cluster access at all.
///
/// It answers `snapshot` from the file and everything else with a plausible minimal payload,
/// because the popover only needs a snapshot to render.
struct FileBackedRunner: RemoteCommandRunner {
    let path: String

    func run(remoteArguments: [String], timeout: TimeInterval) async throws -> RemoteCommandResult {
        // A touch of latency so the refresh spinner behaves as it would for real.
        try? await Task.sleep(nanoseconds: 250_000_000)

        if remoteArguments.contains("snapshot") {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw SSHFailure.remoteAgentMissing(detail: "demo snapshot not found at \(path)")
            }
            return RemoteCommandResult(
                exitCode: 0, standardOutput: data, standardError: "", duration: 0.25
            )
        }

        if remoteArguments.contains("doctor") {
            return RemoteCommandResult(
                exitCode: 0, standardOutput: Data(Self.doctorJSON.utf8), standardError: "", duration: 0.25
            )
        }

        if remoteArguments.contains("logs") {
            return RemoteCommandResult(
                exitCode: 0, standardOutput: Data(Self.logsJSON.utf8), standardError: "", duration: 0.25
            )
        }

        if remoteArguments.contains("gpu") {
            return RemoteCommandResult(
                exitCode: 0, standardOutput: Self.gpuJSON(), standardError: "", duration: 0.25
            )
        }

        // Cancelling is meaningless against a file, and a demo must never look like it worked.
        throw SSHFailure.remoteCommandFailed(
            exitCode: 1, stderr: "demo mode: this action needs a real cluster"
        )
    }

    private static let doctorJSON = """
    {"schema_version":1,"generated_at":"2026-07-22T02:30:00Z","agent_version":"0.2.6","ok":true,
     "hostname":"login.demo.invalid","python_version":"3.11.6","warnings":[],
     "checks":[
      {"id":"agent","title":"SlurmBar agent","status":"ok","detail":null,"value":"0.2.6"},
      {"id":"python","title":"Remote Python","status":"ok","detail":null,"value":"3.11.6"},
      {"id":"slurm_commands","title":"Slurm commands","status":"ok","detail":null,"value":"squeue, sacct, sstat"},
      {"id":"slurm_version","title":"Slurm version","status":"ok","detail":null,"value":"slurm 24.05.0-demo"},
      {"id":"squeue","title":"squeue","status":"ok","detail":null,"value":"9 job(s) in queue"},
      {"id":"squeue_json","title":"squeue --json","status":"ok","detail":"Structured queue output is available.","value":null},
      {"id":"sacct","title":"Accounting (sacct)","status":"ok","detail":"Job history is available.","value":null},
      {"id":"sstat","title":"Live usage (sstat)","status":"ok","detail":null,"value":null},
      {"id":"progress_dir","title":"Progress directory","status":"ok","detail":"4 job directories present.","value":"~/.local/state/slurmbar/jobs"}
     ]}
    """

    private static let logsJSON = """
    {"schema_version":1,"generated_at":"2026-07-22T02:30:00Z","job_id":"10001","stream":"stdout",
     "path":"/home/demo-user/slurmbar-demo/logs/demo-training-10001.out","truncated":true,
     "bytes_read":131072,"file_size_bytes":1048576,"modified_at":"2026-07-22T02:29:58Z","warnings":[],
     "lines":[
      "Epoch 40/100  loss 0.1302  score 0.8010  lr 0.0001",
      "Epoch 41/100  loss 0.1268  score 0.8075  lr 0.0001",
      "Epoch 42/100  loss 0.1234  score 0.8123  lr 0.0001",
      "Epoch 42 [10/25]  loss 0.1234  2.0s/it  mem 8.0GB"
     ]}
    """

    private static func gpuJSON() -> Data {
        func device(
            node: String, index: Int, utilization: Double,
            memoryUsed: Double, power: Double
        ) -> [String: Any] {
            [
                "node": node,
                "index": index,
                "name": "NVIDIA H200",
                "utilization_percent": utilization,
                "memory_used_mib": memoryUsed,
                "memory_total_mib": 143_771.0,
                "power_draw_watts": power,
            ]
        }

        let payload: [String: Any] = [
            "schema_version": 1,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "agent_version": "0.2.6",
            "jobs": [
                [
                    "job_id": "10001", "ok": true, "message": NSNull(),
                    "gpus": [device(
                        node: "demo-accelerator-01", index: 0, utilization: 72,
                        memoryUsed: 32_540, power: 386.2
                    )],
                ],
                [
                    "job_id": "10002", "ok": true, "message": NSNull(),
                    "gpus": [
                        device(node: "demo-accelerator-02", index: 0, utilization: 91, memoryUsed: 61_402, power: 512.7),
                        device(node: "demo-accelerator-02", index: 1, utilization: 84, memoryUsed: 58_116, power: 488.1),
                        device(node: "demo-accelerator-03", index: 0, utilization: 67, memoryUsed: 47_205, power: 421.9),
                        device(node: "demo-accelerator-03", index: 1, utilization: 76, memoryUsed: 50_880, power: 449.3),
                    ],
                ],
            ],
            "warnings": [],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }
}
