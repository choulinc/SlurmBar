import Foundation

// MARK: - doctor

public struct DoctorReport: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let agentVersion: String?
    public let ok: Bool
    public let hostname: String?
    public let pythonVersion: String?
    public let checks: [DoctorCheck]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case agentVersion = "agent_version"
        case ok, hostname, checks
        case pythonVersion = "python_version"
    }

    public init(
        schemaVersion: Int,
        generatedAt: Date,
        agentVersion: String? = nil,
        ok: Bool,
        hostname: String? = nil,
        pythonVersion: String? = nil,
        checks: [DoctorCheck]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.agentVersion = agentVersion
        self.ok = ok
        self.hostname = hostname
        self.pythonVersion = pythonVersion
        self.checks = checks
    }

    public var failures: [DoctorCheck] { checks.filter { $0.status == .fail } }
    public var warnings: [DoctorCheck] { checks.filter { $0.status == .warn } }
}

public struct DoctorCheck: Codable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case ok, warn, fail, skip

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .warn
        }

        /// SF Symbols verified present on macOS 14.
        public var symbolName: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .fail: return "xmark.circle.fill"
            case .skip: return "minus.circle"
            }
        }
    }

    public let id: String
    public let title: String
    public let status: Status
    public let detail: String?
    public let value: String?

    enum CodingKeys: String, CodingKey {
        case id, title, status, detail, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = SanitizedText.clean(try container.decode(String.self, forKey: .title), limit: 100)
        status = try container.decode(Status.self, forKey: .status)
        detail = try container.decodeIfPresent(String.self, forKey: .detail).map { SanitizedText.clean($0, limit: 600) }
        value = try container.decodeIfPresent(String.self, forKey: .value).map { SanitizedText.clean($0, limit: 300) }
    }

    public init(id: String, title: String, status: Status, detail: String? = nil, value: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.value = value
    }
}

// MARK: - logs

public struct LogTail: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let jobID: String
    public let stream: LogStream
    public let path: String?
    public let lines: [String]
    public let bytesRead: Int?
    public let fileSizeBytes: Int64?
    public let truncated: Bool
    public let modifiedAt: Date?
    public let warnings: [AgentWarning]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case jobID = "job_id"
        case stream, path, lines, truncated
        case bytesRead = "bytes_read"
        case fileSizeBytes = "file_size_bytes"
        case modifiedAt = "modified_at"
        case warnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        jobID = try container.decode(String.self, forKey: .jobID)
        stream = try container.decode(LogStream.self, forKey: .stream)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        // The agent already strips control characters; doing it again here means a payload from
        // any source is safe to put straight into a Text view.
        lines = (try container.decodeIfPresent([String].self, forKey: .lines) ?? []).map {
            SanitizedText.clean($0, limit: 4096)
        }
        bytesRead = try container.decodeIfPresent(Int.self, forKey: .bytesRead)
        fileSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
        warnings = try container.decodeIfPresent([AgentWarning].self, forKey: .warnings) ?? []
    }

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date = Date(),
        jobID: String,
        stream: LogStream,
        path: String?,
        lines: [String],
        bytesRead: Int? = nil,
        fileSizeBytes: Int64? = nil,
        truncated: Bool = false,
        modifiedAt: Date? = nil,
        warnings: [AgentWarning] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.jobID = jobID
        self.stream = stream
        self.path = path
        self.lines = lines
        self.bytesRead = bytesRead
        self.fileSizeBytes = fileSizeBytes
        self.truncated = truncated
        self.modifiedAt = modifiedAt
        self.warnings = warnings
    }

    public var text: String { lines.joined(separator: "\n") }
    public var isEmpty: Bool { lines.isEmpty }
}

public enum LogStream: String, Codable, Hashable, CaseIterable, Sendable {
    case stdout, stderr

    public var displayName: String {
        switch self {
        case .stdout: return "Standard output"
        case .stderr: return "Standard error"
        }
    }
}

// MARK: - cancel

public struct CancelResult: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let jobID: String
    public let ok: Bool
    public let exitCode: Int?
    public let message: String?
    public let stderr: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case jobID = "job_id"
        case ok, message, stderr
        case exitCode = "exit_code"
    }

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date = Date(),
        jobID: String,
        ok: Bool,
        exitCode: Int? = nil,
        message: String? = nil,
        stderr: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.jobID = jobID
        self.ok = ok
        self.exitCode = exitCode
        self.message = message
        self.stderr = stderr
    }
}

// MARK: - job detail

public struct JobDetailResponse: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let job: Job
    public let warnings: [AgentWarning]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case job, warnings
    }
}

/// The structured error object the agent prints on stdout when it exits nonzero.
public struct AgentErrorPayload: Codable, Hashable, Sendable {
    public struct Body: Codable, Hashable, Sendable {
        public let code: String
        public let message: String
    }

    public let error: Body
}
