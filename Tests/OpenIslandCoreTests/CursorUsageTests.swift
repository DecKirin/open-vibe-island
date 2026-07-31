import Foundation
import Testing
@testable import OpenIslandCore

struct CursorUsageTests {
    @Test
    func cursorUsageParserReturnsEmptySnapshotForModernUsageBasedPricingAccount() throws {
        // Verified live response shape from a real Team-plan (usage-based
        // pricing) account: every maxRequestUsage field is null.
        let json = """
        {"gpt-4":{"numRequests":0,"numRequestsTotal":0,"numTokens":0,"maxTokenUsage":null,"maxRequestUsage":null},"startOfMonth":"2026-07-02T13:39:40.000Z"}
        """
        let snapshot = try CursorUsageParser.snapshot(from: Data(json.utf8))

        #expect(snapshot.isEmpty)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.startOfMonth != nil)
    }

    @Test
    func cursorUsageParserComputesPercentageForPopulatedQuota() throws {
        let json = """
        {"gpt-4":{"numRequests":125,"numRequestsTotal":125,"numTokens":0,"maxTokenUsage":null,"maxRequestUsage":500},"startOfMonth":"2026-07-02T13:39:40.000Z"}
        """
        let snapshot = try CursorUsageParser.snapshot(from: Data(json.utf8))

        #expect(!snapshot.isEmpty)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.modelName == "gpt-4")
        #expect(snapshot.windows.first?.numRequests == 125)
        #expect(snapshot.windows.first?.maxRequestUsage == 500)
        #expect(snapshot.windows.first?.roundedUsedPercentage == 25)
    }

    @Test
    func cursorUsageParserSkipsModelsWithoutAUsableQuota() throws {
        let json = """
        {
          "gpt-4": {"numRequests": 10, "maxRequestUsage": null},
          "sonnet": {"numRequests": 30, "maxRequestUsage": 100},
          "unused-model": {"numRequests": 0, "maxRequestUsage": 0}
        }
        """
        let snapshot = try CursorUsageParser.snapshot(from: Data(json.utf8))

        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.modelName == "sonnet")
    }

    @Test
    func keychainStoreRoundTripsSaveReadDelete() throws {
        let store = KeychainStore()
        let service = "app.openisland.tests.\(UUID().uuidString)"
        let account = "test-account"

        defer { store.delete(service: service, account: account) }

        #expect(store.read(service: service, account: account) == nil)

        try store.save(service: service, account: account, data: Data("first".utf8))
        #expect(store.read(service: service, account: account) == Data("first".utf8))

        // save() upserts rather than throwing on an existing item.
        try store.save(service: service, account: account, data: Data("second".utf8))
        #expect(store.read(service: service, account: account) == Data("second".utf8))

        #expect(store.delete(service: service, account: account))
        #expect(store.read(service: service, account: account) == nil)
    }

    @Test
    func oauthManagerLoginPollsThrough404sThenPersistsTokens() async throws {
        let (keychain, accessService, refreshService, account) = makeIsolatedKeychain()
        let attempts = Counter()
        let openedURLs = URLBox()

        let manager = CursorUsageOAuthManager(
            keychain: keychain,
            accessTokenService: accessService,
            refreshTokenService: refreshService,
            keychainAccount: account,
            openURL: { url in openedURLs.append(url) },
            transport: { request in
                #expect(request.url?.host == "api2.cursor.sh")
                let attempt = attempts.increment()
                if attempt < 3 {
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
                }
                let body = Data(#"{"accessToken":"\#(makeFakeJWT(expiresIn: 3600))","refreshToken":"refresh-token-value"}"#.utf8)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )

        try await manager.login(pollTimeout: 30)

        #expect(await manager.state == .connected)
        #expect(openedURLs.values.count == 1)
        #expect(openedURLs.values.first?.host == "cursor.com")
        #expect(openedURLs.values.first?.path == "/loginDeepControl")
        #expect(attempts.value == 3)

        keychain.delete(service: accessService, account: account)
        keychain.delete(service: refreshService, account: account)
    }

    @Test
    func oauthManagerEnsureValidAccessTokenRefreshesExpiredToken() async throws {
        let (keychain, accessService, refreshService, account) = makeIsolatedKeychain()
        try keychain.save(service: accessService, account: account, data: Data(makeFakeJWT(expiresIn: -60).utf8))
        try keychain.save(service: refreshService, account: account, data: Data("old-refresh-token".utf8))

        let refreshCalls = Counter()
        let manager = CursorUsageOAuthManager(
            keychain: keychain,
            accessTokenService: accessService,
            refreshTokenService: refreshService,
            keychainAccount: account,
            openURL: { _ in },
            transport: { request in
                _ = refreshCalls.increment()
                #expect(request.url?.path == "/auth/exchange_user_api_key")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-refresh-token")
                let body = Data(#"{"accessToken":"\#(makeFakeJWT(expiresIn: 3600))","refreshToken":"new-refresh-token"}"#.utf8)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )

        let token = try await manager.ensureValidAccessToken()

        #expect(refreshCalls.value == 1)
        #expect(!token.isEmpty)
        #expect(keychain.read(service: refreshService, account: account) == Data("new-refresh-token".utf8))
        #expect(await manager.state == .connected)

        keychain.delete(service: accessService, account: account)
        keychain.delete(service: refreshService, account: account)
    }

    @Test
    func oauthManagerClearsTokensAndSurfacesReauthRequiredOn401() async throws {
        let (keychain, accessService, refreshService, account) = makeIsolatedKeychain()
        try keychain.save(service: accessService, account: account, data: Data(makeFakeJWT(expiresIn: -60).utf8))
        try keychain.save(service: refreshService, account: account, data: Data("revoked-refresh-token".utf8))

        let manager = CursorUsageOAuthManager(
            keychain: keychain,
            accessTokenService: accessService,
            refreshTokenService: refreshService,
            keychainAccount: account,
            openURL: { _ in },
            transport: { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
        )

        await #expect(throws: CursorUsageOAuthManager.OAuthError.self) {
            try await manager.ensureValidAccessToken()
        }

        #expect(await manager.state == .reauthRequired)
        #expect(keychain.read(service: accessService, account: account) == nil)
        #expect(keychain.read(service: refreshService, account: account) == nil)
    }
}

private func makeIsolatedKeychain() -> (KeychainStore, String, String, String) {
    let suffix = UUID().uuidString
    return (
        KeychainStore(),
        "app.openisland.tests.cursor-access.\(suffix)",
        "app.openisland.tests.cursor-refresh.\(suffix)",
        "test-cursor-user"
    )
}

/// Builds a syntactically valid (unsigned) JWT with a given `exp` claim so
/// expiry-driven logic can be exercised without a real Cursor token.
private func makeFakeJWT(expiresIn seconds: TimeInterval) -> String {
    let header = base64URLEncode(Data(#"{"alg":"none"}"#.utf8))
    let exp = Int(Date().addingTimeInterval(seconds).timeIntervalSince1970)
    let payload = base64URLEncode(Data(#"{"exp":\#(exp)}"#.utf8))
    return "\(header).\(payload).signature"
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
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

private final class URLBox: @unchecked Sendable {
    private(set) var values: [URL] = []

    func append(_ url: URL) {
        values.append(url)
    }
}
