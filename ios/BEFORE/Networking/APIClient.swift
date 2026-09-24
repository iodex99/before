import Foundation
import BeforeKit

// =============================================================================
// BEFORE — HTTP client.
//
// The only place in the app that knows about URLs, status codes, or JSON. View
// code never touches it directly; it goes View -> ViewModel -> Repository ->
// APIClient (spec §46, §85).
// =============================================================================

public protocol TokenProviding: Sendable {
    /// A valid access token, refreshing if needed. Throws when signed out.
    func accessToken() async throws -> String
}

public protocol APIClientProtocol: Sendable {
    func send<Response: Decodable & Sendable>(
        _ request: APIRequest,
        as type: Response.Type
    ) async throws -> Response

    func send(_ request: APIRequest) async throws

    /// The response body, undecoded. For the data export, which is a document
    /// the user receives rather than a model the app reads.
    func sendRaw(_ request: APIRequest) async throws -> Data
}

// MARK: - Request

public struct APIRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    public let method: Method
    public let path: String
    public let query: [URLQueryItem]
    public let body: Data?
    /// Sent as Idempotency-Key. Required for anything that costs a quota unit.
    public let idempotencyKey: String?
    public let timeout: TimeInterval
    /// Some requests (sign-in bootstrap) must not trigger a token refresh loop.
    public let requiresAuth: Bool

    public init(
        method: Method,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        idempotencyKey: String? = nil,
        timeout: TimeInterval = 30,
        requiresAuth: Bool = true
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.idempotencyKey = idempotencyKey
        self.timeout = timeout
        self.requiresAuth = requiresAuth
    }

    public static func get(_ path: String, query: [URLQueryItem] = []) -> APIRequest {
        APIRequest(method: .get, path: path, query: query)
    }

    public static func post(
        _ path: String,
        body: some Encodable,
        idempotencyKey: String? = nil,
        timeout: TimeInterval = 30
    ) throws -> APIRequest {
        APIRequest(
            method: .post,
            path: path,
            body: try JSON.encoder.encode(body),
            idempotencyKey: idempotencyKey,
            timeout: timeout
        )
    }

    public static func patch(_ path: String, body: some Encodable) throws -> APIRequest {
        APIRequest(method: .patch, path: path, body: try JSON.encoder.encode(body))
    }
}

// MARK: - Coding

public enum JSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Postgres timestamps carry fractional seconds; the plain .iso8601
        // strategy rejects them, which is a genuinely easy way to break every
        // date in the app.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: raw) { return date }
            if let date = plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unrecognised date: \(raw)")
            )
        }
        return decoder
    }()
}

// MARK: - Client

public final class APIClient: APIClientProtocol, @unchecked Sendable {
    private let baseURL: URL
    private let anonKey: String
    private let tokenProvider: TokenProviding
    private let session: URLSession

    /// Transient failures only, and only for requests that are safe to repeat.
    private let maxRetries = 2

    public init(
        baseURL: URL,
        anonKey: String,
        tokenProvider: TokenProviding,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.tokenProvider = tokenProvider

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 90
            configuration.waitsForConnectivity = false
            configuration.httpAdditionalHeaders = ["accept": "application/json"]
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: Sending

    public func send<Response: Decodable & Sendable>(
        _ request: APIRequest,
        as type: Response.Type
    ) async throws -> Response {
        let data = try await perform(request)
        do {
            return try JSON.decoder.decode(Response.self, from: data)
        } catch {
            #if DEBUG
            print("[APIClient] decoding \(Response.self) failed: \(error)")
            #endif
            throw APIError.decodingFailed
        }
    }

    public func send(_ request: APIRequest) async throws {
        _ = try await perform(request)
    }

    public func sendRaw(_ request: APIRequest) async throws -> Data {
        try await perform(request)
    }

    private func perform(_ request: APIRequest) async throws -> Data {
        var attempt = 0

        while true {
            do {
                return try await performOnce(request)
            } catch let error as APIError {
                attempt += 1

                // Retrying a mutation without an idempotency key risks doing the
                // work twice, so it is only safe for GETs and for requests that
                // carry a key (spec §50).
                let repeatable = request.method == .get || request.idempotencyKey != nil
                guard error.isRetryable, repeatable, attempt <= maxRetries else { throw error }

                try await Task.sleep(nanoseconds: backoffNanoseconds(for: attempt, error: error))
                try Task.checkCancellation()
            }
        }
    }

    private func backoffNanoseconds(for attempt: Int, error: APIError) -> UInt64 {
        // Honour Retry-After when the server sent one; otherwise exponential.
        if case .rateLimited(let retryAfter) = error, let retryAfter {
            return UInt64(min(retryAfter, 10) * 1_000_000_000)
        }
        let seconds = pow(2.0, Double(attempt - 1)) * 0.5
        return UInt64(min(seconds, 4) * 1_000_000_000)
    }

    private func performOnce(_ request: APIRequest) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(request.path),
            resolvingAgainstBaseURL: false
        )
        if !request.query.isEmpty { components?.queryItems = request.query }

        guard let url = components?.url else { throw APIError.invalidRequest("bad url") }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")

        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        if let key = request.idempotencyKey {
            urlRequest.setValue(key, forHTTPHeaderField: "idempotency-key")
        }
        if request.requiresAuth {
            let token = try await tokenProvider.accessToken()
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw APIError.offline
            case .timedOut:
                throw APIError.timedOut
            case .cancelled:
                throw CancellationError()
            default:
                throw APIError.offline
            }
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.decodingFailed }

        if (200..<300).contains(http.statusCode) { return data }

        let retryAfter = (http.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init)

        // Prefer the server's own error code; it is more specific than status.
        if let body = try? JSON.decoder.decode(APIErrorBody.self, from: data) {
            throw APIError.from(code: body.error.code, status: http.statusCode, retryAfter: retryAfter)
        }
        throw APIError.from(status: http.statusCode, retryAfter: retryAfter)
    }
}
