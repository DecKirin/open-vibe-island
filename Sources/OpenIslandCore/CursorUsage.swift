import Foundation
import SQLite3

// MARK: - Public types

public struct CursorUsageWindow: Equatable, Codable, Sendable, Identifiable {
    public var label: String
    public var usedPercentage: Double

    public init(label: String, usedPercentage: Double) {
        self.label = label
        self.usedPercentage = usedPercentage
    }

    public var id: String { label }

    public var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

public struct CursorUsageSnapshot: Equatable, Codable, Sendable {
    public var windows: [CursorUsageWindow]
    public var capturedAt: Date?

    public init(windows: [CursorUsageWindow], capturedAt: Date? = nil) {
        self.windows = windows
        self.capturedAt = capturedAt
    }

    public var isEmpty: Bool {
        windows.isEmpty
    }
}

// MARK: - CursorUsageLoader
//
// Cursor exposes no supported local API for usage/quota data — `cursor-agent`
// CLI, its hook payloads, and Cursor's official Team Analytics API (which is
// Enterprise-only, team-scoped, and reports spend/counts, not a personal %)
// were all ruled out during development. What actually works, verified live
// against a real account and cross-checked against a reference product's
// traffic, is calling Cursor IDE's own internal dashboard API directly:
//
//   1. Cursor IDE already has a valid session token cached locally the
//      moment you're logged into the IDE — `cursorAuth/accessToken` in its
//      global-storage SQLite DB (`state.vscdb`). This is a JWT
//      (aud: https://cursor.com, iss: https://authentication.cursor.sh,
//      type: session) that Cursor IDE itself uses for its own dashboard
//      calls. No separate login/OAuth flow is needed — if Cursor IDE is
//      installed and logged in, this file already has what's needed.
//
//   2. The endpoint that returns real usage data is NOT the public REST API
//      (`cursor.com/api/usage-summary`, `api2.cursor.sh/auth/usage`) — both
//      were tested and are dead ends (the former needs a *different*,
//      browser-only session token; the latter is a deprecated endpoint that
//      returns null fields under Cursor's current usage-based pricing). The
//      real data comes from Cursor IDE's *internal* Connect-RPC API:
//      `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
//      — the same call the IDE itself makes to render its own usage UI.
//
//   3. That internal API additionally expects an `x-cursor-checksum` header
//      that *looks* like an auth mechanism but isn't one — it's the "Jyh
//      cipher", a hardcoded-key XOR-with-feedback obfuscation of the current
//      ~16-minute-resolution timestamp, concatenated with the machine's
//      local telemetry IDs. This has been independently reverse-engineered
//      and published (see `CursorChecksum` below) — it's deliberately weak
//      by design (the server only checks the header is *present* and
//      well-formed, not that it's cryptographically correct), used for
//      coarse fingerprinting/anti-replay, not authentication. The real
//      authentication is entirely the Bearer JWT from step 1.
//
// Because there is no `.proto` schema available for `GetCurrentPeriodUsage`,
// the response is *not* parsed as structured protobuf. Instead this reads
// the human-readable summary strings Cursor embeds directly in the encoded
// response (e.g. "You've used 48% of your included total usage") via regex.
// This is deliberately the more fragile of two possible approaches — full
// field-number-based protobuf parsing would survive a wording change, this
// would not — but it needs no `.proto` definitions to maintain and Cursor's
// own IDE renders these exact strings verbatim, so they're unlikely to
// disappear without the corresponding UI also changing. If the response
// shape changes such that these patterns stop matching, this degrades to
// an empty snapshot (no chip shown) rather than a crash or a stale number.
public enum CursorUsageLoader {
    private static let dashboardUsageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!

    public static func load(
        session: CursorLocalSession = .defaultReader,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
            = { request in try await URLSession.shared.data(for: request) }
    ) async throws -> CursorUsageSnapshot? {
        guard let credentials = session.readCredentials() else {
            // No local Cursor IDE session (not installed, or not logged in
            // yet) — same "quietly absent" behavior as Claude/Codex when
            // their respective local sources don't exist.
            return nil
        }

        var request = URLRequest(url: dashboardUsageURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("application/proto", forHTTPHeaderField: "content-type")
        request.setValue(
            CursorChecksum.generate(
                machineId: credentials.machineId,
                macMachineId: credentials.macMachineId
            ),
            forHTTPHeaderField: "x-cursor-checksum"
        )
        request.setValue("ide", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue("desktop", forHTTPHeaderField: "x-cursor-client-device-type")
        request.setValue("darwin", forHTTPHeaderField: "x-cursor-client-os")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-session-id")
        request.setValue(Self.randomHexClientKey(), forHTTPHeaderField: "x-client-key")
        // Explicitly ask for an uncompressed body: the response embeds the
        // usage strings this loader regex-matches on, and avoiding gzip
        // means no decompression step is needed.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let teamID = credentials.teamID {
            request.setValue(teamID, forHTTPHeaderField: "x-cursor-team-id")
        }

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            // Covers an expired/invalidated Cursor IDE session (401/403) and
            // any transient failure alike — there is no "reconnect" action
            // for the user to take here (that happens by logging into
            // Cursor IDE itself), so this just quietly withholds data
            // rather than surfacing an error state.
            return nil
        }

        return CursorUsageResponseParser.snapshot(from: data, capturedAt: Date())
    }

    private static func randomHexClientKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0 ... 255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Response parsing

enum CursorUsageResponseParser {
    private static let totalPattern = try! NSRegularExpression(
        pattern: #"used (\d+)% of your included total usage"#
    )
    private static let apiPattern = try! NSRegularExpression(
        pattern: #"used (\d+)% of your included API usage"#
    )

    static func snapshot(from data: Data, capturedAt: Date?) -> CursorUsageSnapshot {
        // The response is a Connect-RPC-framed protobuf message, but the
        // summary strings it contains are plain UTF-8 substrings within
        // that binary payload — decoding it as Latin-1 (lossless, 1
        // byte-per-scalar) is enough to run text regexes over it without
        // needing a protobuf decoder.
        guard let text = String(data: data, encoding: .isoLatin1) else {
            return CursorUsageSnapshot(windows: [], capturedAt: capturedAt)
        }

        var windows: [CursorUsageWindow] = []
        if let percentage = firstMatch(totalPattern, in: text) {
            windows.append(CursorUsageWindow(label: "Total", usedPercentage: percentage))
        }
        if let percentage = firstMatch(apiPattern, in: text) {
            windows.append(CursorUsageWindow(label: "API", usedPercentage: percentage))
        }

        return CursorUsageSnapshot(windows: windows, capturedAt: capturedAt)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> Double? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[numberRange])
    }
}

// MARK: - Checksum ("Jyh cipher")
//
// Independently reverse-engineered and published (not discovered here) —
// a deliberately weak obfuscation cipher with a hardcoded initial key,
// documented as intentionally non-cryptographic by its original authors.
// It is not a secret Open Island needs to protect; it exists only so the
// request has the same *shape* Cursor IDE's own requests have.
enum CursorChecksum {
    private static let initialKey: UInt8 = 165
    private static let base64URLAlphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    static func generate(machineId: String, macMachineId: String?) -> String {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000) / 1_000_000
        var bytes: [UInt8] = [
            UInt8((timestamp >> 40) & 0xFF),
            UInt8((timestamp >> 32) & 0xFF),
            UInt8((timestamp >> 24) & 0xFF),
            UInt8((timestamp >> 16) & 0xFF),
            UInt8((timestamp >> 8) & 0xFF),
            UInt8(timestamp & 0xFF),
        ]

        var key = initialKey
        for i in bytes.indices {
            let value = (bytes[i] ^ key) &+ UInt8(i % 256)
            bytes[i] = value
            key = value
        }

        let encoded = base64URLEncode(bytes)
        guard let macMachineId else { return "\(encoded)\(machineId)" }
        return "\(encoded)\(machineId)/\(macMachineId)"
    }

    private static func base64URLEncode(_ bytes: [UInt8]) -> String {
        var result = ""
        var index = 0
        while index < bytes.count {
            let a = bytes[index]
            let b = index + 1 < bytes.count ? bytes[index + 1] : 0
            let c = index + 2 < bytes.count ? bytes[index + 2] : 0

            result.append(base64URLAlphabet[Int(a >> 2)])
            result.append(base64URLAlphabet[Int(((a & 0x03) << 4) | (b >> 4))])
            if index + 1 < bytes.count {
                result.append(base64URLAlphabet[Int(((b & 0x0F) << 2) | (c >> 6))])
            }
            if index + 2 < bytes.count {
                result.append(base64URLAlphabet[Int(c & 0x3F)])
            }
            index += 3
        }
        return result
    }
}

// MARK: - Local session reader

public struct CursorLocalCredentials: Equatable, Sendable {
    public var accessToken: String
    public var machineId: String
    public var macMachineId: String?
    public var teamID: String?
}

/// Reads Cursor IDE's own local session — no credentials are stored or
/// managed by Open Island itself, this only ever reflects whatever Cursor
/// IDE already has cached on disk right now.
public struct CursorLocalSession: Sendable {
    public static let defaultReader = CursorLocalSession()

    private let globalStorageDirectory: URL
    private let cliConfigURL: URL

    public init(
        applicationSupportDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor", isDirectory: true),
        cursorHomeDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
    ) {
        globalStorageDirectory = applicationSupportDirectory
            .appendingPathComponent("User/globalStorage", isDirectory: true)
        cliConfigURL = cursorHomeDirectory.appendingPathComponent("cli-config.json")
    }

    public func readCredentials() -> CursorLocalCredentials? {
        guard let accessToken = readAccessToken(), let machineId = readMachineId() else {
            return nil
        }
        return CursorLocalCredentials(
            accessToken: accessToken,
            machineId: machineId,
            macMachineId: readMacMachineId(),
            teamID: readTeamID()
        )
    }

    private func readAccessToken() -> String? {
        readSQLiteValue(
            at: globalStorageDirectory.appendingPathComponent("state.vscdb"),
            key: "cursorAuth/accessToken"
        )
    }

    private func readMachineId() -> String? {
        readStorageJSONField("telemetry.machineId")
    }

    private func readMacMachineId() -> String? {
        readStorageJSONField("telemetry.macMachineId")
    }

    private func readStorageJSONField(_ key: String) -> String? {
        let url = globalStorageDirectory.appendingPathComponent("storage.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object[key] as? String
    }

    private func readTeamID() -> String? {
        guard let data = try? Data(contentsOf: cliConfigURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authInfo = object["authInfo"] as? [String: Any] else {
            return nil
        }
        if let teamID = authInfo["teamId"] as? NSNumber {
            return teamID.stringValue
        }
        if let teamID = authInfo["teamId"] as? String {
            return teamID
        }
        return nil
    }

    /// Minimal read-only `SELECT value FROM ItemTable WHERE key = ?` — this
    /// is VS Code/Cursor's own global-storage schema, not something Open
    /// Island defines. Degrades to nil on any error (missing file, locked
    /// DB, schema mismatch, Cursor not installed) rather than throwing —
    /// callers already treat "no Cursor session" as an expected, silent
    /// state.
    private func readSQLiteValue(at url: URL, key: String) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var db: OpaquePointer?
        let flags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) else {
            return nil
        }

        // `cursorAuth/accessToken` is stored as a bare (unquoted) string —
        // verified directly against a real installation, not merely
        // assumed from generic VS Code storage conventions.
        return String(cString: cString)
    }
}
