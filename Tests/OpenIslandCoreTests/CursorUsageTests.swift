import Foundation
import SQLite3
import Testing
@testable import OpenIslandCore

struct CursorUsageTests {
    // MARK: - CursorChecksum

    @Test
    func checksumEmbedsMachineIdAndMacMachineIdVerbatim() {
        let checksum = CursorChecksum.generate(machineId: "machine-id-value", macMachineId: "mac-machine-id-value")
        #expect(checksum.contains("machine-id-value/mac-machine-id-value"))
        // 8-character base64url-encoded timestamp prefix precedes the IDs.
        #expect(checksum.count == 8 + "machine-id-value".count + 1 + "mac-machine-id-value".count)
    }

    @Test
    func checksumOmitsSlashWhenMacMachineIdMissing() {
        let checksum = CursorChecksum.generate(machineId: "machine-id-value", macMachineId: nil)
        #expect(checksum == "\(checksum.prefix(8))machine-id-value")
        #expect(!checksum.contains("/"))
    }

    // MARK: - CursorUsageResponseParser

    @Test
    func parserExtractsPercentagesFromEmbeddedSummarySentences() {
        // The real response is Connect-RPC-framed protobuf with binary
        // field markers surrounding these exact sentences (verified live
        // against a real account: "You've used 48% of your included total
        // usage" / "...0% of your included API usage"). Binary framing
        // bytes are stand-ins here — what's under test is the regex
        // extraction, not exact byte-for-byte protobuf reproduction.
        var bytes: [UInt8] = [0x0A, 0x63, 0x01, 0x02, 0xFF, 0x00]
        bytes.append(contentsOf: Array("You've hit your usage limit".utf8))
        bytes.append(contentsOf: [0x5A, 0x2C])
        bytes.append(contentsOf: Array("You've used 48% of your included total usage".utf8))
        bytes.append(contentsOf: [0x62, 0x29])
        bytes.append(contentsOf: Array("You've used 0% of your included API usage".utf8))
        bytes.append(contentsOf: [0x6A, 0x07])

        let snapshot = CursorUsageResponseParser.snapshot(from: Data(bytes), capturedAt: nil)

        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.first(where: { $0.label == "Total" })?.roundedUsedPercentage == 48)
        #expect(snapshot.windows.first(where: { $0.label == "API" })?.roundedUsedPercentage == 0)
    }

    @Test
    func parserReturnsEmptySnapshotWhenSummaryStringsAbsent() {
        let data = Data("unrelated protobuf noise with no usage sentences".utf8)
        let snapshot = CursorUsageResponseParser.snapshot(from: data, capturedAt: nil)
        #expect(snapshot.isEmpty)
    }

    // MARK: - CursorLocalSession

    @Test
    func readCredentialsParsesTokenAndMachineIdsFromLocalFixtures() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeStateVscdb(
            at: root.appendingPathComponent("Cursor/User/globalStorage/state.vscdb"),
            accessToken: "fixture-access-token"
        )
        try writeStorageJSON(
            at: root.appendingPathComponent("Cursor/User/globalStorage/storage.json"),
            machineId: "fixture-machine-id",
            macMachineId: "fixture-mac-machine-id"
        )
        try writeCLIConfig(at: root.appendingPathComponent(".cursor/cli-config.json"), teamID: 12345)

        let session = CursorLocalSession(
            applicationSupportDirectory: root.appendingPathComponent("Cursor"),
            cursorHomeDirectory: root.appendingPathComponent(".cursor")
        )

        let credentials = try #require(session.readCredentials())
        #expect(credentials.accessToken == "fixture-access-token")
        #expect(credentials.machineId == "fixture-machine-id")
        #expect(credentials.macMachineId == "fixture-mac-machine-id")
        #expect(credentials.teamID == "12345")
    }

    @Test
    func readCredentialsReturnsNilWhenStateVscdbMissing() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-cursor-missing-\(UUID().uuidString)", isDirectory: true)
        let session = CursorLocalSession(
            applicationSupportDirectory: root.appendingPathComponent("Cursor"),
            cursorHomeDirectory: root.appendingPathComponent(".cursor")
        )
        #expect(session.readCredentials() == nil)
    }

    // MARK: - CursorUsageLoader

    @Test
    func loaderReturnsNilWithoutAnyNetworkCallWhenNoLocalSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-cursor-loader-\(UUID().uuidString)", isDirectory: true)
        let session = CursorLocalSession(
            applicationSupportDirectory: root.appendingPathComponent("Cursor"),
            cursorHomeDirectory: root.appendingPathComponent(".cursor")
        )

        let transportCalled = Counter()
        let snapshot = try await CursorUsageLoader.load(session: session) { request in
            transportCalled.increment()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        #expect(snapshot == nil)
        #expect(transportCalled.value == 0)
    }

    @Test
    func loaderSendsBearerAndChecksumHeadersAndParsesResponse() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeStateVscdb(
            at: root.appendingPathComponent("Cursor/User/globalStorage/state.vscdb"),
            accessToken: "fixture-access-token"
        )
        try writeStorageJSON(
            at: root.appendingPathComponent("Cursor/User/globalStorage/storage.json"),
            machineId: "fixture-machine-id",
            macMachineId: "fixture-mac-machine-id"
        )

        let session = CursorLocalSession(
            applicationSupportDirectory: root.appendingPathComponent("Cursor"),
            cursorHomeDirectory: root.appendingPathComponent(".cursor")
        )

        let responseBody = Data("You've used 33% of your included total usage".utf8)
        let snapshot = try await CursorUsageLoader.load(session: session) { request in
            #expect(request.url?.absoluteString == "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access-token")
            #expect(request.value(forHTTPHeaderField: "x-cursor-checksum")?.contains("fixture-machine-id/fixture-mac-machine-id") == true)
            return (responseBody, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let unwrapped = try #require(snapshot)
        #expect(unwrapped.windows.first(where: { $0.label == "Total" })?.roundedUsedPercentage == 33)
    }

    @Test
    func loaderReturnsNilOnUnauthorizedResponse() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeStateVscdb(
            at: root.appendingPathComponent("Cursor/User/globalStorage/state.vscdb"),
            accessToken: "fixture-access-token"
        )
        try writeStorageJSON(
            at: root.appendingPathComponent("Cursor/User/globalStorage/storage.json"),
            machineId: "fixture-machine-id",
            macMachineId: nil
        )

        let session = CursorLocalSession(
            applicationSupportDirectory: root.appendingPathComponent("Cursor"),
            cursorHomeDirectory: root.appendingPathComponent(".cursor")
        )

        let snapshot = try await CursorUsageLoader.load(session: session) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }

        #expect(snapshot == nil)
    }
}

// MARK: - Fixture helpers

private func makeFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("open-island-cursor-usage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeStateVscdb(at url: URL, accessToken: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        Issue.record("Failed to create fixture state.vscdb")
        return
    }
    defer { sqlite3_close(db) }

    guard sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE, value BLOB);", nil, nil, nil) == SQLITE_OK else {
        Issue.record("Failed to create ItemTable schema")
        return
    }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else {
        Issue.record("Failed to prepare insert")
        return
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, "cursorAuth/accessToken", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(statement, 2, accessToken, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(statement) == SQLITE_DONE else {
        Issue.record("Failed to insert fixture row")
        return
    }
}

private func writeStorageJSON(at url: URL, machineId: String, macMachineId: String?) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var payload: [String: Any] = ["telemetry.machineId": machineId]
    if let macMachineId {
        payload["telemetry.macMachineId"] = macMachineId
    }
    try JSONSerialization.data(withJSONObject: payload).write(to: url)
}

private func writeCLIConfig(at url: URL, teamID: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let payload: [String: Any] = ["authInfo": ["teamId": teamID]]
    try JSONSerialization.data(withJSONObject: payload).write(to: url)
}

/// Mutable counter shared with a `@Sendable` transport closure. Tests only
/// ever call the closure sequentially (awaited), so a lock isn't needed —
/// `@unchecked` just satisfies the compiler's static Sendable check.
private final class Counter: @unchecked Sendable {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
