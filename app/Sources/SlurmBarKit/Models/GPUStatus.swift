import Foundation

/// An on-demand reading from `nvidia-smi` inside the currently running allocations.
public struct GPUStatusResponse: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let agentVersion: String?
    public let jobs: [GPUJobStatus]
    public let warnings: [AgentWarning]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case agentVersion = "agent_version"
        case jobs, warnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        agentVersion = try container.decodeIfPresent(String.self, forKey: .agentVersion).map {
            SanitizedText.clean($0, limit: 80)
        }
        jobs = Array(try container.decode([GPUJobStatus].self, forKey: .jobs).prefix(64))
        warnings = try container.decodeIfPresent([AgentWarning].self, forKey: .warnings) ?? []
    }
}

public struct GPUJobStatus: Codable, Hashable, Identifiable, Sendable {
    public let jobID: String
    public let ok: Bool
    public let message: String?
    public let gpus: [GPUDevice]

    public var id: String { jobID }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case ok, message, gpus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(String.self, forKey: .jobID)
        guard JobIDValidator.isValid(decodedID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .jobID,
                in: container,
                debugDescription: "Expected an ASCII Slurm job id."
            )
        }
        jobID = decodedID
        ok = try container.decode(Bool.self, forKey: .ok)
        message = try container.decodeIfPresent(String.self, forKey: .message).map {
            SanitizedText.clean($0, limit: 500)
        }
        gpus = Array(try container.decode([GPUDevice].self, forKey: .gpus).prefix(4096))
    }
}

public struct GPUDevice: Codable, Hashable, Identifiable, Sendable {
    public let node: String
    public let index: Int
    public let name: String
    public let utilizationPercent: Double?
    public let memoryUsedMiB: Double?
    public let memoryTotalMiB: Double?
    public let powerDrawWatts: Double?

    public var id: String { "\(node)#\(index)" }

    enum CodingKeys: String, CodingKey {
        case node, index, name
        case utilizationPercent = "utilization_percent"
        case memoryUsedMiB = "memory_used_mib"
        case memoryTotalMiB = "memory_total_mib"
        case powerDrawWatts = "power_draw_watts"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedNode = SanitizedText.clean(
            try container.decode(String.self, forKey: .node), limit: 160
        )
        node = decodedNode.isEmpty ? "unknown" : decodedNode
        index = min(max(0, try container.decode(Int.self, forKey: .index)), 4096)
        name = SanitizedText.clean(try container.decode(String.self, forKey: .name), limit: 160)
        utilizationPercent = Self.bounded(
            try container.decodeIfPresent(Double.self, forKey: .utilizationPercent), maximum: 100
        )
        memoryUsedMiB = Self.bounded(
            try container.decodeIfPresent(Double.self, forKey: .memoryUsedMiB), maximum: 16_777_216
        )
        memoryTotalMiB = Self.bounded(
            try container.decodeIfPresent(Double.self, forKey: .memoryTotalMiB), maximum: 16_777_216
        )
        powerDrawWatts = Self.bounded(
            try container.decodeIfPresent(Double.self, forKey: .powerDrawWatts), maximum: 100_000
        )
    }

    private static func bounded(_ value: Double?, maximum: Double) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, maximum)
    }

    public var memoryFraction: Double? {
        guard let used = memoryUsedMiB, let total = memoryTotalMiB, total > 0 else { return nil }
        return min(1, max(0, used / total))
    }
}
