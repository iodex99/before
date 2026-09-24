import Foundation
import BeforeKit

// =============================================================================
// BEFORE — image upload.
//
// Two-step by design: the client uploads to its own storage prefix first, then
// sends the path to the analysis endpoint (see DECISIONS.md).
//
//   - A multi-megabyte base64 body never crosses the wire.
//   - A failed upload can be retried without re-running the analysis, and
//     without spending a quota unit.
//   - Storage RLS enforces the `<user-id>/` prefix, so a client cannot write
//     into someone else's folder even if it tries.
// =============================================================================

public protocol ImageUploading: Sendable {
    /// Returns the storage path the analysis endpoint should be given.
    func uploadAnalysisImage(_ data: Data, userId: String) async throws -> String
}

public struct StorageService: ImageUploading {
    private let baseURL: URL
    private let anonKey: String
    private let tokenProvider: TokenProviding
    private let session: URLSession

    public init(
        supabaseURL: URL = AppConfig.supabaseURL,
        anonKey: String = AppConfig.supabaseAnonKey,
        tokenProvider: TokenProviding,
        session: URLSession = .shared
    ) {
        self.baseURL = supabaseURL
        self.anonKey = anonKey
        self.tokenProvider = tokenProvider
        self.session = session
    }

    public func uploadAnalysisImage(_ data: Data, userId: String) async throws -> String {
        // The prefix is not decoration: the storage policy matches on it.
        let path = "\(userId)/\(UUID().uuidString).jpg"
        let url = baseURL
            .appendingPathComponent("storage/v1/object/analyses")
            .appendingPathComponent(path)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await tokenProvider.accessToken())", forHTTPHeaderField: "authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "content-type")
        request.setValue("3600", forHTTPHeaderField: "cache-control")
        request.httpBody = data
        request.timeoutInterval = 60

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw error.code == .timedOut ? APIError.timedOut : APIError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.decodingFailed }
        guard (200..<300).contains(http.statusCode) else {
            // 413 from storage means the bucket's own size limit rejected it.
            throw http.statusCode == 413
                ? APIError.imageTooLarge
                : APIError.from(status: http.statusCode, retryAfter: nil)
        }

        return path
    }
}

/// Used by previews and UI tests.
public struct MockImageUploader: ImageUploading {
    public init() {}
    public func uploadAnalysisImage(_ data: Data, userId: String) async throws -> String {
        "\(userId)/preview.jpg"
    }
}
