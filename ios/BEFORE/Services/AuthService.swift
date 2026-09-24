import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import BeforeKit

// =============================================================================
// BEFORE — authentication.
//
// Sign in with Apple only (spec §6). No Google, no email, no password.
//
// Apple credentials are never stored by us. What we keep is the Supabase
// session that results from exchanging Apple's identity token, and that lives
// in the Keychain — never in UserDefaults or SwiftData (spec §47).
// =============================================================================

@MainActor
@Observable
public final class AuthService: NSObject {

    public enum State: Equatable {
        case unknown
        case signedOut
        case signedIn(userId: String)

        public var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    public private(set) var state: State = .unknown
    public private(set) var isWorking = false
    public private(set) var lastError: String?

    private let keychain: KeychainStore
    private let supabaseURL: URL
    private let anonKey: String
    private let session: URLSession

    /// The nonce for the in-flight Apple request. Apple echoes its SHA-256 back
    /// inside the identity token; comparing them is what stops a token captured
    /// elsewhere from being replayed here.
    private var currentNonce: String?

    public init(
        keychain: KeychainStore = KeychainStore(),
        supabaseURL: URL = AppConfig.supabaseURL,
        anonKey: String = AppConfig.supabaseAnonKey,
        session: URLSession = .shared
    ) {
        self.keychain = keychain
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
        self.session = session
        super.init()
    }

    // MARK: - Session

    /// Restore a session at launch without blocking the UI (spec §83).
    public func restore() async {
        guard keychain.string(for: .accessToken) != nil,
              let refresh = keychain.string(for: .refreshToken)
        else {
            state = .signedOut
            return
        }

        do {
            let session = try await refreshSession(refreshToken: refresh)
            store(session)
            state = .signedIn(userId: session.userId)
        } catch {
            // A refresh token that no longer works means signed out, not an
            // error screen — the user just signs in again.
            clearSession()
            state = .signedOut
        }
    }

    public func signOut() {
        clearSession()
        state = .signedOut
    }

    // MARK: - Sign in with Apple

    /// Configure the ASAuthorization request. Called from the button's
    /// `onRequest` so the nonce is generated per attempt.
    public func prepare(request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName]  // no email: we do not need one
        request.nonce = Self.sha256(nonce)
    }

    public func handle(_ result: Result<ASAuthorization, Error>) async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        switch result {
        case .failure(let error):
            // A user tapping Cancel is not an error worth showing.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            lastError = "Sign in didn't complete. Please try again."

        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8),
                let nonce = currentNonce
            else {
                lastError = "Sign in didn't complete. Please try again."
                return
            }

            do {
                let session = try await exchange(
                    identityToken: identityToken,
                    nonce: nonce,
                    fullName: credential.fullName
                )
                store(session)
                state = .signedIn(userId: session.userId)
            } catch {
                lastError = "We couldn't sign you in. Please try again."
            }
            currentNonce = nil
        }
    }

    // MARK: - Supabase exchange

    private struct SessionResponse: Decodable {
        struct User: Decodable { let id: String }
        let access_token: String
        let refresh_token: String
        let user: User

        var userId: String { user.id }
    }

    private func exchange(
        identityToken: String,
        nonce: String,
        fullName: PersonNameComponents?
    ) async throws -> SessionResponse {
        struct Body: Encodable {
            let provider = "apple"
            let id_token: String
            let nonce: String
        }

        var request = URLRequest(url: supabaseURL.appendingPathComponent("auth/v1/token"))
        request.url?.append(queryItems: [URLQueryItem(name: "grant_type", value: "id_token")])
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(
            Body(id_token: identityToken, nonce: nonce)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.unauthorized
        }

        let session = try JSONDecoder().decode(SessionResponse.self, from: data)

        // Apple supplies a name only on the FIRST authorisation, and only if
        // the user allowed it. If we do not capture it now, it is gone forever.
        if let fullName, let displayName = Self.formatted(fullName) {
            await storeDisplayName(displayName, accessToken: session.access_token)
        }

        return session
    }

    private func refreshSession(refreshToken: String) async throws -> SessionResponse {
        struct Body: Encodable { let refresh_token: String }

        var request = URLRequest(url: supabaseURL.appendingPathComponent("auth/v1/token"))
        request.url?.append(queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(Body(refresh_token: refreshToken))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.unauthorized
        }
        return try JSONDecoder().decode(SessionResponse.self, from: data)
    }

    private func storeDisplayName(_ name: String, accessToken: String) async {
        struct Body: Encodable { let data: [String: String] }

        var request = URLRequest(url: supabaseURL.appendingPathComponent("auth/v1/user"))
        request.httpMethod = "PUT"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONEncoder().encode(Body(data: ["full_name": name]))

        _ = try? await session.data(for: request)
    }

    private func store(_ session: SessionResponse) {
        try? keychain.set(session.access_token, for: .accessToken)
        try? keychain.set(session.refresh_token, for: .refreshToken)
    }

    private func clearSession() {
        keychain.remove(.accessToken)
        keychain.remove(.refreshToken)
        // The appAccountToken deliberately survives: it must stay stable so a
        // reinstall reconciles against the same subscription record.
    }

    // MARK: - Nonce

    private static func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        guard status == errSecSuccess else {
            // Without a secure nonce the replay protection is gone, so failing
            // loudly beats signing someone in with a weak one.
            fatalError("Unable to generate a secure nonce (SecRandomCopyBytes: \(status))")
        }
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func formatted(_ components: PersonNameComponents) -> String? {
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let name = formatter.string(from: components).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

// MARK: - Token provision

/// Supplies a valid token to the APIClient, refreshing when needed.
public final class KeychainTokenProvider: TokenProviding, @unchecked Sendable {
    private let keychain: KeychainStore
    private let refresh: @Sendable () async -> Void

    public init(keychain: KeychainStore = KeychainStore(), refresh: @escaping @Sendable () async -> Void) {
        self.keychain = keychain
        self.refresh = refresh
    }

    public func accessToken() async throws -> String {
        if let token = keychain.string(for: .accessToken) { return token }
        await refresh()
        guard let token = keychain.string(for: .accessToken) else { throw APIError.unauthorized }
        return token
    }
}
