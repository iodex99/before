import Foundation

// =============================================================================
// BEFORE — API errors.
//
// Every failure the user can reach has a sentence written for them. Spec §45:
// no "Error 2", ever.
// =============================================================================

public enum APIError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    /// The free monthly allowance is used up. The caller shows the paywall.
    case quotaExceeded
    /// A Plus subscriber past the monthly fair-use ceiling. NOT a paywall —
    /// they already pay. See docs/LIMITS.md.
    case fairUseExceeded(resetsInSeconds: TimeInterval?)
    case rateLimited(retryAfter: TimeInterval?)
    case invalidRequest(String?)
    case imageTooLarge
    case imageUnreadable
    case urlUnreadable
    case analysisFailed
    case providerUnavailable
    case contentUnsupported
    case notFound
    case conflict
    case offline
    case timedOut
    case decodingFailed
    case server(status: Int)

    /// Maps a server error code to its case. Unknown codes fall back by status
    /// so a new server-side code never produces a blank screen.
    static func from(code: String, status: Int, retryAfter: TimeInterval?) -> APIError {
        switch code {
        case "unauthorized": .unauthorized
        case "forbidden": .forbidden
        case "quota_exceeded": .quotaExceeded
        case "fair_use_exceeded": .fairUseExceeded(resetsInSeconds: retryAfter)
        case "rate_limited": .rateLimited(retryAfter: retryAfter)
        case "invalid_request": .invalidRequest(nil)
        case "image_too_large": .imageTooLarge
        case "image_unreadable": .imageUnreadable
        case "url_unreadable": .urlUnreadable
        case "analysis_failed": .analysisFailed
        case "provider_unavailable": .providerUnavailable
        case "content_unsupported": .contentUnsupported
        case "not_found": .notFound
        case "conflict": .conflict
        default: .server(status: status)
        }
    }

    static func from(status: Int, retryAfter: TimeInterval?) -> APIError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 402: .quotaExceeded
        case 404: .notFound
        case 409: .conflict
        case 413: .imageTooLarge
        case 429: .rateLimited(retryAfter: retryAfter)
        default: .server(status: status)
        }
    }

    /// Worth trying again by itself. A quota failure is not; a timeout is.
    public var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .providerUnavailable, .rateLimited:
            true
        case .server(let status):
            status >= 500
        default:
            false
        }
    }
}

extension APIError: LocalizedError {
    public var errorDescription: String? { userMessage }

    /// Shown to the user verbatim.
    public var userMessage: String {
        switch self {
        case .unauthorized:
            "Please sign in again."
        case .forbidden:
            "You don't have access to that."
        case .quotaExceeded:
            "You've used all your checks this month."
        case .fairUseExceeded:
            "You've hit this month's fair-use limit."
        case .rateLimited:
            "Give it a moment and try again."
        case .invalidRequest(let detail):
            detail ?? "Something about that request didn't look right."
        case .imageTooLarge, .imageUnreadable:
            "That image is too large or couldn't be read. Try another photo."
        case .urlUnreadable:
            "We couldn't read the product page. You can still send us a screenshot."
        case .analysisFailed, .providerUnavailable:
            "We couldn't finish that analysis."
        case .contentUnsupported:
            "We couldn't analyse that image. Try a photo of the product itself."
        case .notFound:
            "We couldn't find that."
        case .conflict:
            "That was already being processed."
        case .offline:
            "You're offline. BEFORE needs a connection to check something new."
        case .timedOut:
            "That took too long. Try again."
        case .decodingFailed, .server:
            "Something went wrong on our side."
        }
    }

    /// A second line, where there is something genuinely useful to add.
    public var recoverySuggestion: String? {
        switch self {
        case .quotaExceeded: "BEFORE Plus gives you unlimited checks."
        // Deliberately not an upsell: they already subscribe.
        case .fairUseExceeded: "It resets at the start of next month."
        case .offline: "Your saved items and history are still here."
        case .urlUnreadable: "Some shops block automated readers."
        default: nil
        }
    }
}
