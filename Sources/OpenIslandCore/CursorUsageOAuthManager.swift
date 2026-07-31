import CryptoKit
import Foundation
import Security

/// Drives Cursor's own account login (`cursor.com/loginDeepControl` +
/// `api2.cursor.sh/auth/poll`) — a browser-approve-then-poll flow with no
/// local redirect/callback server involved. Tokens obtained this way are
/// scoped to `api2.cursor.sh` only; they are not valid against
/// `cursor.com`'s own website-session-gated endpoints (verified live).
public actor CursorUsageOAuthManager {
    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reauthRequired
        case error(String)
    }

    public enum OAuthError: LocalizedError, Sendable {
        case notConnected
        case pollingTimedOut
        case cancelled
        case reauthRequired
        case invalidResponse
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected: "Cursor is not connected."
            case .pollingTimedOut: "Timed out waiting for Cursor sign-in approval."
            case .cancelled: "Cursor sign-in was cancelled."
            case .reauthRequired: "Cursor session expired — reconnect required."
            case .invalidResponse: "Cursor returned an unexpected response."
            case let .network(message): message
            }
        }
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let loginURL = "https://cursor.com/loginDeepControl"
    private static let pollURL = "https://api2.cursor.sh/auth/poll"
    private static let refreshURL = "https://api2.cursor.sh/auth/exchange_user_api_key"
    private static let usageURL = "https://api2.cursor.sh/auth/usage"

    private static let pollBaseDelayMilliseconds: Int64 = 1000
    private static let pollMaxDelayMilliseconds: Int64 = 10000
    private static let pollBackoffMultiplier: Double = 1.2
    private static let refreshLeewaySeconds: TimeInterval = 300

    private let keychain: KeychainStore
    private let accessTokenService: String
    private let refreshTokenService: String
    private let keychainAccount: String
    private let openURL: @Sendable (URL) -> Void
    private let transport: Transport

    public private(set) var state: ConnectionState

    public init(
        keychain: KeychainStore = KeychainStore(),
        accessTokenService: String = "app.openisland.cursor-access-token",
        refreshTokenService: String = "app.openisland.cursor-refresh-token",
        keychainAccount: String = "cursor-user",
        openURL: @escaping @Sendable (URL) -> Void,
        transport: @escaping Transport = { request in try await URLSession.shared.data(for: request) }
    ) {
        self.keychain = keychain
        self.accessTokenService = accessTokenService
        self.refreshTokenService = refreshTokenService
        self.keychainAccount = keychainAccount
        self.openURL = openURL
        self.transport = transport
        state = keychain.read(service: refreshTokenService, account: keychainAccount) != nil
            ? .connected
            : .disconnected
    }

    public func login(pollTimeout: TimeInterval = 180) async throws {
        state = .connecting
        do {
            let params = try Self.generateAuthParams()
            openURL(params.loginURL)
            let tokens = try await poll(uuid: params.uuid, verifier: params.verifier, timeout: pollTimeout)
            try persist(tokens)
            state = .connected
        } catch {
            state = .disconnected
            throw error
        }
    }

    public func disconnect() {
        clearStoredTokens()
        state = .disconnected
    }

    public func ensureValidAccessToken() async throws -> String {
        guard let accessData = keychain.read(service: accessTokenService, account: keychainAccount),
              let accessToken = String(data: accessData, encoding: .utf8) else {
            state = .disconnected
            throw OAuthError.notConnected
        }

        if let expiry = Self.expirationDate(fromJWT: accessToken),
           expiry.timeIntervalSinceNow > Self.refreshLeewaySeconds {
            state = .connected
            return accessToken
        }

        let tokens = try await refreshTokens()
        return tokens.accessToken
    }

    public func fetchUsageSnapshot() async throws -> CursorUsageSnapshot {
        let accessToken = try await ensureValidAccessToken()

        var request = URLRequest(url: URL(string: Self.usageURL)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }

        if http.statusCode == 401 || http.statusCode == 403 {
            clearStoredTokens()
            state = .reauthRequired
            throw OAuthError.reauthRequired
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OAuthError.network("Cursor usage fetch failed with status \(http.statusCode)")
        }

        let snapshot = try CursorUsageParser.snapshot(from: data, capturedAt: Date())
        state = .connected
        return snapshot
    }

    // MARK: - Token refresh

    private func refreshTokens() async throws -> CursorOAuthTokens {
        guard let refreshData = keychain.read(service: refreshTokenService, account: keychainAccount),
              let refreshToken = String(data: refreshData, encoding: .utf8) else {
            state = .disconnected
            throw OAuthError.notConnected
        }

        var request = URLRequest(url: URL(string: Self.refreshURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }

        if http.statusCode == 401 || http.statusCode == 403 {
            clearStoredTokens()
            state = .reauthRequired
            throw OAuthError.reauthRequired
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OAuthError.network("Cursor token refresh failed with status \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(CursorPollResponse.self, from: data)
        let tokens = CursorOAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken.isEmpty ? refreshToken : decoded.refreshToken
        )
        try persist(tokens)
        state = .connected
        return tokens
    }

    // MARK: - Login polling

    private func poll(uuid: String, verifier: String, timeout: TimeInterval) async throws -> CursorOAuthTokens {
        let deadline = Date().addingTimeInterval(timeout)
        var delayMilliseconds = Self.pollBaseDelayMilliseconds
        var consecutiveErrors = 0

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(delayMilliseconds))

            var components = URLComponents(string: Self.pollURL)!
            components.queryItems = [
                URLQueryItem(name: "uuid", value: uuid),
                URLQueryItem(name: "verifier", value: verifier),
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"

            do {
                let (data, response) = try await transport(request)
                guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }

                if http.statusCode == 404 {
                    consecutiveErrors = 0
                    delayMilliseconds = min(
                        Int64(Double(delayMilliseconds) * Self.pollBackoffMultiplier),
                        Self.pollMaxDelayMilliseconds
                    )
                    continue
                }
                if (200 ..< 300).contains(http.statusCode) {
                    let decoded = try JSONDecoder().decode(CursorPollResponse.self, from: data)
                    return CursorOAuthTokens(accessToken: decoded.accessToken, refreshToken: decoded.refreshToken)
                }
                throw OAuthError.invalidResponse
            } catch is CancellationError {
                throw OAuthError.cancelled
            } catch let error as OAuthError {
                throw error
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    throw OAuthError.network(error.localizedDescription)
                }
            }
        }

        throw OAuthError.pollingTimedOut
    }

    // MARK: - Helpers

    private func clearStoredTokens() {
        keychain.delete(service: accessTokenService, account: keychainAccount)
        keychain.delete(service: refreshTokenService, account: keychainAccount)
    }

    private func persist(_ tokens: CursorOAuthTokens) throws {
        try keychain.save(service: accessTokenService, account: keychainAccount, data: Data(tokens.accessToken.utf8))
        try keychain.save(service: refreshTokenService, account: keychainAccount, data: Data(tokens.refreshToken.utf8))
    }

    private struct AuthParams {
        let verifier: String
        let uuid: String
        let loginURL: URL
    }

    private static func generateAuthParams() throws -> AuthParams {
        var verifierBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, verifierBytes.count, &verifierBytes)
        guard status == errSecSuccess else { throw OAuthError.invalidResponse }

        let verifier = base64URLEncode(Data(verifierBytes))
        let challengeDigest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(challengeDigest))
        let uuid = UUID().uuidString.lowercased()

        var components = URLComponents(string: loginURL)!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "redirectTarget", value: "cli"),
        ]
        guard let url = components.url else { throw OAuthError.invalidResponse }

        return AuthParams(verifier: verifier, uuid: uuid, loginURL: url)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func expirationDate(fromJWT token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }

        guard let payloadData = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let exp = json["exp"] as? NSNumber else {
            return nil
        }

        return Date(timeIntervalSince1970: exp.doubleValue)
    }
}

private struct CursorOAuthTokens: Sendable {
    let accessToken: String
    let refreshToken: String
}

private struct CursorPollResponse: Decodable {
    let accessToken: String
    let refreshToken: String
}
