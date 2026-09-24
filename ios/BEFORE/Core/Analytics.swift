import Foundation
import BeforeKit

// =============================================================================
// BEFORE — analytics.
//
// A provider-neutral abstraction, so vendor calls never get scattered through
// the UI (spec §44) and so swapping PostHog for something else is one file.
//
// The property type is a closed enum rather than a dictionary. That is the
// whole design: you cannot put a raw image, a URL with a token, or someone's
// purchase history into an event, because there is nowhere to put it.
// =============================================================================

public enum AnalyticsEvent: String, Sendable {
    case onboardingStarted = "onboarding_started"
    case onboardingCompleted = "onboarding_completed"
    case analysisStarted = "analysis_started"
    case analysisCompleted = "analysis_completed"
    case analysisFailed = "analysis_failed"
    case verdictViewed = "verdict_viewed"
    case itemSaved = "item_saved"
    case itemBought = "item_bought"
    case itemSkipped = "item_skipped"
    case itemReturned = "item_returned"
    case wardrobeItemAdded = "wardrobe_item_added"
    case shareStarted = "share_started"
    case shareCompleted = "share_completed"
    case shareImported = "share_imported"
    case paywallViewed = "paywall_viewed"
    case subscriptionStarted = "subscription_started"
    case restoreStarted = "restore_started"
    case restoreCompleted = "restore_completed"
    case accountDeleted = "account_deleted"
}

/// The only properties an event may carry. Adding one is a deliberate act.
public struct AnalyticsProperties: Sendable {
    public var category: ProductCategory?
    public var verdict: Verdict?
    /// Bucketed, never the exact score.
    public var scoreBucket: String?
    public var inputType: InputType?
    public var subscriptionState: String?
    /// A short, developer-chosen identifier — a paywall placement, an error
    /// code. Never user content and never model output.
    public var context: String?

    public init(
        category: ProductCategory? = nil,
        verdict: Verdict? = nil,
        score: Int? = nil,
        inputType: InputType? = nil,
        isPlus: Bool? = nil,
        context: String? = nil
    ) {
        self.category = category
        self.verdict = verdict
        self.scoreBucket = score.map(Formatting.scoreBucket)
        self.inputType = inputType
        self.subscriptionState = isPlus.map { $0 ? "plus" : "free" }
        self.context = context
    }

    public var dictionary: [String: String] {
        var result: [String: String] = [:]
        if let category { result["category"] = category.rawValue }
        if let verdict { result["verdict"] = verdict.rawValue }
        if let scoreBucket { result["score_bucket"] = scoreBucket }
        if let inputType { result["input_type"] = inputType.rawValue }
        if let subscriptionState { result["subscription_state"] = subscriptionState }
        if let context { result["context"] = context }
        return result
    }
}

public protocol AnalyticsSink: Sendable {
    func record(_ event: AnalyticsEvent, properties: AnalyticsProperties)
}

/// Prints to the console. The default in DEBUG.
public struct ConsoleAnalyticsSink: AnalyticsSink {
    public init() {}
    public func record(_ event: AnalyticsEvent, properties: AnalyticsProperties) {
        let details = properties.dictionary
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        print("[analytics] \(event.rawValue) \(details)")
    }
}

/// Drops everything. Used when the user has not consented, and in UI tests.
public struct NoOpAnalyticsSink: AnalyticsSink {
    public init() {}
    public func record(_ event: AnalyticsEvent, properties: AnalyticsProperties) {}
}

/// The call site the rest of the app uses: `Analytics.track(.analysisStarted)`.
public enum Analytics {
    nonisolated(unsafe) private static var sink: AnalyticsSink = {
        #if DEBUG
        ConsoleAnalyticsSink()
        #else
        NoOpAnalyticsSink()
        #endif
    }()

    private static let lock = NSLock()

    public static func configure(sink newSink: AnalyticsSink) {
        lock.lock()
        defer { lock.unlock() }
        sink = newSink
    }

    public static func track(_ event: AnalyticsEvent, _ properties: AnalyticsProperties = .init()) {
        lock.lock()
        let current = sink
        lock.unlock()
        current.record(event, properties: properties)
    }

    /// Convenience for the most common shape.
    public static func track(_ event: AnalyticsEvent, analysis: Analysis, isPlus: Bool) {
        track(event, AnalyticsProperties(
            category: analysis.product.category,
            verdict: analysis.verdict,
            score: analysis.score,
            isPlus: isPlus
        ))
    }
}
