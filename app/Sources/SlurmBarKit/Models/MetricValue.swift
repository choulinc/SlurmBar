import Foundation

/// A single free-form metric reported by a workload.
///
/// The protocol allows numbers, strings, booleans and null. NaN and infinity arrive as the
/// strings `"nan"`, `"inf"` and `"-inf"` because JSON cannot represent them — and a NaN loss is
/// exactly the kind of thing a user wants a notification about, so it is preserved rather than
/// dropped.
public enum MetricValue: Codable, Hashable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// The numeric value, if this metric is genuinely numeric. `"nan"` is *not* coerced to a
    /// number here; use ``isNaN`` for that.
    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value.isFinite ? value : nil
        case .string(let text): return Double(text).flatMap { $0.isFinite ? $0 : nil }
        case .bool, .null: return nil
        }
    }

    /// True when the workload reported a NaN. This is the signal behind the "loss became NaN"
    /// notification.
    public var isNaN: Bool {
        switch self {
        case .number(let value): return value.isNaN
        case .string(let text): return text.lowercased() == "nan"
        default: return false
        }
    }

    public var isInfinite: Bool {
        switch self {
        case .number(let value): return value.isInfinite
        case .string(let text): return ["inf", "-inf", "infinity", "-infinity"].contains(text.lowercased())
        default: return false
        }
    }

    /// A compact human-readable rendering suitable for a dense menu bar row.
    public var displayString: String {
        switch self {
        case .null:
            return "N/A"
        case .bool(let value):
            return value ? "yes" : "no"
        case .string(let text):
            return SanitizedText.clean(text, limit: 80)
        case .number(let value):
            return MetricValue.formatNumber(value)
        }
    }

    static func formatNumber(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "∞" : "-∞" }
        if value == value.rounded(), abs(value) < 1e9 {
            return String(Int(value))
        }
        let magnitude = abs(value)
        if magnitude != 0, magnitude < 0.001 || magnitude >= 1e6 {
            return String(format: "%.3g", value)
        }
        return String(format: "%.4g", value)
    }
}
