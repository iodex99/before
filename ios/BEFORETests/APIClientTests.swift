import XCTest
@testable import BEFORE
@testable import BeforeKit

// =============================================================================
// Networking — every status the server can return, plus the ones the network
// can inflict on us (spec §68).
//
// No real requests: a URLProtocol stub intercepts everything, so the suite is
// deterministic and runs offline.
// =============================================================================

final class APIClientTests: XCTestCase {

    private var client: APIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]

        client = APIClient(
            baseURL: URL(string: "https://example.test/functions/v1")!,
            anonKey: "anon-key",
            tokenProvider: StubTokenProvider(token: "test-token"),
            session: URLSession(configuration: configuration)
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    // MARK: Success

    func testDecodesASuccessfulResponse() async throws {
        StubURLProtocol.respond(status: 200, json: Self.usageJSON)

        let usage = try await client.send(.get("usage"), as: UsageSnapshot.self)

        XCTAssertEqual(usage.used, 1)
        XCTAssertEqual(usage.limit, 5)
        XCTAssertEqual(usage.remaining, 4)
        XCTAssertFalse(usage.isPlus)
    }

    func testSendsAuthAndApiKeyHeaders() async throws {
        StubURLProtocol.respond(status: 200, json: Self.usageJSON)
        _ = try await client.send(.get("usage"), as: UsageSnapshot.self)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key")
    }

    func testSendsIdempotencyKeyWhenSupplied() async throws {
        StubURLProtocol.respond(status: 200, json: "{}")

        let request = APIRequest(method: .post, path: "analyze-purchase", idempotencyKey: "key-123")
        try await client.send(request)

        XCTAssertEqual(
            StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "idempotency-key"),
            "key-123"
        )
    }

    // MARK: Errors

    func testMapsServerErrorCodesToTypedErrors() async {
        let cases: [(Int, String, APIError)] = [
            (400, "invalid_request", .invalidRequest(nil)),
            (401, "unauthorized", .unauthorized),
            (403, "forbidden", .forbidden),
            (402, "quota_exceeded", .quotaExceeded),
            (413, "image_too_large", .imageTooLarge),
            (422, "url_unreadable", .urlUnreadable),
            (502, "analysis_failed", .analysisFailed),
        ]

        for (status, code, expected) in cases {
            StubURLProtocol.respond(
                status: status,
                json: #"{"error":{"code":"\#(code)","message":"m","requestId":"r"}}"#
            )
            do {
                _ = try await client.send(.get("usage"), as: UsageSnapshot.self)
                XCTFail("expected \(code) to throw")
            } catch let error as APIError {
                XCTAssertEqual(error, expected, "for \(status)/\(code)")
            } catch {
                XCTFail("unexpected error type for \(code): \(error)")
            }
        }
    }

    func testFallsBackToStatusWhenTheBodyIsNotOurErrorShape() async {
        StubURLProtocol.respond(status: 401, json: "<html>nope</html>")
        await assertThrows(.unauthorized) { _ = try await self.client.send(.get("usage"), as: UsageSnapshot.self) }
    }

    func testRateLimitCarriesRetryAfter() async {
        StubURLProtocol.respond(
            status: 429,
            json: #"{"error":{"code":"rate_limited","message":"m","requestId":"r"}}"#,
            headers: ["retry-after": "30"]
        )

        do {
            _ = try await client.send(.get("usage"), as: UsageSnapshot.self)
            XCTFail("expected a rate limit error")
        } catch let error as APIError {
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("expected rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAfter, 30)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMalformedJsonFailsAsDecodingRatherThanCrashing() async {
        StubURLProtocol.respond(status: 200, json: #"{"used": "not a number"}"#)
        await assertThrows(.decodingFailed) {
            _ = try await self.client.send(.get("usage"), as: UsageSnapshot.self)
        }
    }

    func testOfflineIsReportedAsOffline() async {
        StubURLProtocol.fail(with: URLError(.notConnectedToInternet))
        await assertThrows(.offline) {
            _ = try await self.client.send(.get("usage"), as: UsageSnapshot.self)
        }
    }

    func testTimeoutIsReportedAsTimeout() async {
        StubURLProtocol.fail(with: URLError(.timedOut))
        await assertThrows(.timedOut) {
            _ = try await self.client.send(.get("usage"), as: UsageSnapshot.self)
        }
    }

    // MARK: Retries

    func testRetriesATransientFailureOnAGet() async throws {
        StubURLProtocol.respondInSequence([
            (503, #"{"error":{"code":"provider_unavailable","message":"m","requestId":"r"}}"#),
            (200, Self.usageJSON),
        ])

        let usage = try await client.send(.get("usage"), as: UsageSnapshot.self)
        XCTAssertEqual(usage.used, 1)
        XCTAssertEqual(StubURLProtocol.requestCount, 2, "should have retried once")
    }

    func testDoesNotRetryAPostWithoutAnIdempotencyKey() async {
        StubURLProtocol.respond(
            status: 503,
            json: #"{"error":{"code":"provider_unavailable","message":"m","requestId":"r"}}"#
        )

        do {
            try await client.send(APIRequest(method: .post, path: "analyze-purchase"))
            XCTFail("expected a failure")
        } catch {
            // Retrying a mutation with no idempotency key could do the work
            // twice and charge the user twice.
            XCTAssertEqual(StubURLProtocol.requestCount, 1)
        }
    }

    func testDoesNotRetryANonRetryableError() async {
        StubURLProtocol.respond(
            status: 402,
            json: #"{"error":{"code":"quota_exceeded","message":"m","requestId":"r"}}"#
        )

        await assertThrows(.quotaExceeded) {
            _ = try await self.client.send(.get("usage"), as: UsageSnapshot.self)
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "a quota failure is not worth retrying")
    }

    // MARK: Helpers

    private static let usageJSON = """
    {
      "periodStart": "2026-09-01T00:00:00Z",
      "periodEnd": "2026-10-01T00:00:00Z",
      "used": 1,
      "limit": 5,
      "remaining": 4,
      "isPlus": false
    }
    """

    private func assertThrows(
        _ expected: APIError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: @escaping () async throws -> Void
    ) async {
        do {
            try await block()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}

// MARK: - Stubs

struct StubTokenProvider: TokenProviding {
    let token: String
    func accessToken() async throws -> String { token }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var queue: [(Int, String, [String: String])] = []
    nonisolated(unsafe) private static var error: Error?
    nonisolated(unsafe) static private(set) var requestCount = 0
    nonisolated(unsafe) static private(set) var lastRequest: URLRequest?
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        error = nil
        requestCount = 0
        lastRequest = nil
    }

    static func respond(status: Int, json: String, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        queue = [(status, json, headers)]
        error = nil
    }

    static func respondInSequence(_ responses: [(Int, String)]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses.map { ($0.0, $0.1, [:]) }
        error = nil
    }

    static func fail(with failure: Error) {
        lock.lock(); defer { lock.unlock() }
        error = failure
        queue = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        Self.lastRequest = request
        let failure = Self.error
        // The last queued response repeats, so a test does not have to enqueue
        // one per retry attempt.
        let response = Self.queue.count > 1 ? Self.queue.removeFirst() : Self.queue.first
        Self.lock.unlock()

        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        guard let (status, json, headers) = response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["content-type": "application/json"]) { a, _ in a }
        )!

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
