import Foundation

/// Decodes agent payloads, treating everything from the remote side as untrusted.
///
/// Three gates before any model is constructed:
/// 1. a hard byte limit, so a runaway remote command cannot exhaust memory;
/// 2. a `schema_version` check, so an unknown protocol produces an actionable message rather
///    than a half-decoded snapshot;
/// 3. structured errors, so the UI can distinguish "malformed JSON" from "agent said no".
public struct ProtocolDecoder: Sendable {
    /// The protocol revision this build implements.
    public static let supportedSchemaVersion = 1

    /// Generous for a snapshot of thousands of jobs, far below anything dangerous.
    public static let maxPayloadBytes = 16 * 1024 * 1024

    public init() {}

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = iso8601.date(from: text) ?? iso8601Fractional.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a UTC ISO 8601 timestamp, got \(text)"
                )
            )
        }
        return decoder
    }

    // MARK: - Entry points

    public func decodeSnapshot(from data: Data) throws -> Snapshot {
        try decode(Snapshot.self, from: data, versionKey: "schema_version", label: "snapshot")
    }

    public func decodeDoctorReport(from data: Data) throws -> DoctorReport {
        try decode(DoctorReport.self, from: data, versionKey: "schema_version", label: "doctor report")
    }

    public func decodeLogTail(from data: Data) throws -> LogTail {
        try decode(LogTail.self, from: data, versionKey: "schema_version", label: "log tail")
    }

    public func decodeCancelResult(from data: Data) throws -> CancelResult {
        try decode(CancelResult.self, from: data, versionKey: "schema_version", label: "cancel result")
    }

    public func decodeJobDetail(from data: Data) throws -> JobDetailResponse {
        try decode(JobDetailResponse.self, from: data, versionKey: "schema_version", label: "job detail")
    }

    // MARK: - Core

    private func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        versionKey: String,
        label: String
    ) throws -> T {
        guard !data.isEmpty else {
            throw ProtocolError.emptyResponse
        }
        guard data.count <= Self.maxPayloadBytes else {
            throw ProtocolError.payloadTooLarge(bytes: data.count, limit: Self.maxPayloadBytes)
        }

        // Peek at the envelope first: an error object or an unsupported version must not be
        // reported to the user as a generic decoding failure.
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProtocolError.malformedJSON(preview: Self.preview(of: data))
        }

        if let errorBody = object["error"] as? [String: Any] {
            throw ProtocolError.agentError(
                code: errorBody["code"] as? String ?? "AGENT_ERROR",
                message: errorBody["message"] as? String ?? "The agent reported an error."
            )
        }

        guard let version = object[versionKey] as? Int else {
            throw ProtocolError.missingSchemaVersion(label: label)
        }
        guard version == Self.supportedSchemaVersion else {
            throw ProtocolError.unsupportedSchemaVersion(
                found: version,
                supported: Self.supportedSchemaVersion
            )
        }

        do {
            return try Self.makeJSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw ProtocolError.decodingFailed(label: label, detail: Self.describe(error))
        }
    }

    static func preview(of data: Data) -> String {
        let text = String(decoding: data.prefix(400), as: UTF8.self)
        return SanitizedText.clean(text, limit: 400)
    }

    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing field '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "missing value of type \(type) at \(path(context))"
        case .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context))"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "the top level" : path
    }
}

/// Failures that occur after SSH succeeded but before a usable model exists.
public enum ProtocolError: Error, LocalizedError, Hashable {
    case emptyResponse
    case payloadTooLarge(bytes: Int, limit: Int)
    case malformedJSON(preview: String)
    case missingSchemaVersion(label: String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case decodingFailed(label: String, detail: String)
    case agentError(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "The agent returned no output."
        case .payloadTooLarge(let bytes, let limit):
            return "The agent returned \(bytes) bytes, above the \(limit) byte safety limit."
        case .malformedJSON:
            return "The agent's response was not valid JSON."
        case .missingSchemaVersion(let label):
            return "The \(label) response did not declare a schema version."
        case .unsupportedSchemaVersion(let found, let supported):
            return "The remote agent speaks protocol v\(found); this version of SlurmBar speaks v\(supported)."
        case .decodingFailed(let label, let detail):
            return "The \(label) response could not be read: \(detail)"
        case .agentError(_, let message):
            return message
        }
    }

    /// What the user should actually do about it.
    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return found > supported
                ? "Update SlurmBar on this Mac."
                : "Reinstall the remote agent with scripts/install-agent.sh."
        case .malformedJSON:
            return "A shell startup file on the login node may be printing text on login. "
                + "Check that a non-interactive SSH session prints nothing extra."
        case .emptyResponse:
            return "Check that the remote agent is installed at the configured path."
        case .agentError:
            return nil
        default:
            return nil
        }
    }
}
