import Foundation

public struct CursorUsageWindow: Equatable, Codable, Sendable, Identifiable {
    public var modelName: String
    public var usedPercentage: Double
    public var numRequests: Int
    public var maxRequestUsage: Int

    public init(modelName: String, usedPercentage: Double, numRequests: Int, maxRequestUsage: Int) {
        self.modelName = modelName
        self.usedPercentage = usedPercentage
        self.numRequests = numRequests
        self.maxRequestUsage = maxRequestUsage
    }

    public var id: String { modelName }

    public var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

public struct CursorUsageSnapshot: Equatable, Codable, Sendable {
    public var windows: [CursorUsageWindow]
    public var startOfMonth: Date?
    public var capturedAt: Date?

    public init(windows: [CursorUsageWindow], startOfMonth: Date?, capturedAt: Date? = nil) {
        self.windows = windows
        self.startOfMonth = startOfMonth
        self.capturedAt = capturedAt
    }

    public var isEmpty: Bool {
        windows.isEmpty
    }
}

/// Parses the response of `GET https://api2.cursor.sh/auth/usage`.
///
/// This is Cursor's legacy per-model request-quota endpoint. On accounts using
/// Cursor's current usage-based pricing, every `maxRequestUsage` field is `null`
/// (verified live against a real Team-plan account) — an empty snapshot is the
/// expected common case here, not a parsing failure.
public enum CursorUsageParser {
    public static func snapshot(from data: Data, capturedAt: Date? = nil) throws -> CursorUsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let payload = object as? [String: Any] else {
            return CursorUsageSnapshot(windows: [], startOfMonth: nil, capturedAt: capturedAt)
        }

        let startOfMonth = date(from: payload["startOfMonth"])

        var windows: [CursorUsageWindow] = []
        for (key, value) in payload {
            guard key != "startOfMonth", let modelPayload = value as? [String: Any] else { continue }
            guard let maxRequestUsage = integer(from: modelPayload["maxRequestUsage"]), maxRequestUsage > 0 else {
                continue
            }
            let numRequests = integer(from: modelPayload["numRequests"]) ?? 0
            let usedPercentage = min(100, max(0, Double(numRequests) / Double(maxRequestUsage) * 100))
            windows.append(
                CursorUsageWindow(
                    modelName: key,
                    usedPercentage: usedPercentage,
                    numRequests: numRequests,
                    maxRequestUsage: maxRequestUsage
                )
            )
        }

        windows.sort { $0.modelName < $1.modelName }

        return CursorUsageSnapshot(windows: windows, startOfMonth: startOfMonth, capturedAt: capturedAt)
    }

    private static func integer(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string)
        default:
            nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        switch value {
        case let value as NSNumber:
            return Date(timeIntervalSince1970: value.doubleValue)
        case let value as String:
            let formatterWithFractionalSeconds = ISO8601DateFormatter()
            formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatterWithFractionalSeconds.date(from: value) {
                return date
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        default:
            return nil
        }
    }
}
