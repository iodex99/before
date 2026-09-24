import Foundation
import BeforeKit

// =============================================================================
// BEFORE — fixtures and mock repositories.
//
// Used by SwiftUI previews, UI tests, and AppConfig.useMockData. The numbers
// match backend/shared/fixtures/ai-responses.json, which the backend test suite
// asserts against the real score engine — so a preview shows the same verdict
// the server would produce, not an invented one.
//
// Spec §71: demo data must never ship unlabelled. `MockAnalysisRepository` is
// only ever constructed under DEBUG or a UI-test launch argument.
// =============================================================================

public enum Fixtures {

    public static func factor(
        _ key: SignalKey,
        _ value: Double,
        weight: Double,
        included: Bool = true,
        reason: String? = nil
    ) -> FactorScore {
        FactorScore(key: key, value: value, weight: weight, included: included, excludedReason: reason)
    }

    /// The demo item from the spec: black leather jacket, $198, WAIT 78.
    public static var leatherJacket: Analysis {
        Analysis(
            analysisId: "fixture-leather-jacket",
            status: .completed,
            createdAt: .now,
            product: ProductFacts(
                name: "Cropped leather jacket",
                brand: nil,
                category: .fashion,
                subcategory: "outerwear",
                price: 198,
                currency: "USD",
                retailer: nil,
                material: "Leather",
                sources: [
                    "price": .confirmed,
                    "category": .confirmed,
                    "material": .estimated,
                    "brand": .unknown,
                ],
                priceConfidence: 0.95,
                identityConfidence: 0.6
            ),
            visual: VisualAnalysis(
                colors: ["black"],
                styleTags: ["minimal", "classic", "edgy"],
                occasionTags: ["everyday", "evening"],
                versatilityEstimate: 84,
                visualQualityConfidence: 0.7
            ),
            score: 78,
            verdict: .wait,
            confidence: 0.74,
            confidenceLabel: .medium,
            factors: [
                factor(.wardrobeCompatibility, 9.0, weight: 0.25),
                factor(.duplicationRisk, 4.8, weight: 0.15),
                factor(.expectedUsage, 8.8, weight: 0.15),
                factor(.styleMatch, 9.3, weight: 0.15),
                factor(.valueForMoney, 7.4, weight: 0.15),
                factor(.budgetFit, 7.2, weight: 0.10),
                factor(.wardrobeGap, 6.6, weight: 0.05),
            ],
            reasons: AnalysisReasons(
                positive: [
                    "Works with the neutrals that make up most of what you own",
                    "Black outerwear is the highest-wear category in your history",
                    "The cropped cut suits the trousers you already wear most",
                ],
                negative: [
                    "You own a black moto jacket that covers a similar occasion",
                    "This is above your usual outerwear spend",
                ],
                keyRisk: "It overlaps with a jacket you already reach for.",
                advice: "Wait 48 hours. If you are still thinking about it, come back.",
                uncertainties: [
                    "Brand not confidently identified",
                    "Material estimated from the image, not confirmed",
                ]
            ),
            suggestedAction: .wait48Hours,
            imageUrl: nil,
            promptVersion: "purchase_analysis_v1",
            scoreAlgorithmVersion: "score_v1"
        )
    }

    /// BUY 88.
    public static var loafers: Analysis {
        var analysis = leatherJacket
        analysis.analysisId = "fixture-loafers"
        analysis.createdAt = .now.addingTimeInterval(-2 * 86_400)
        analysis.product = ProductFacts(
            name: "Leather loafers",
            category: .fashion,
            subcategory: "shoes",
            price: 145,
            currency: "USD",
            sources: ["price": .confirmed, "category": .confirmed],
            priceConfidence: 0.92,
            identityConfidence: 0.78
        )
        analysis.score = 88
        analysis.verdict = .buy
        analysis.confidence = 0.83
        analysis.confidenceLabel = .high
        analysis.suggestedAction = .buyIt
        analysis.factors = [
            factor(.wardrobeCompatibility, 9.2, weight: 0.25),
            factor(.duplicationRisk, 8.8, weight: 0.15),
            factor(.expectedUsage, 9.0, weight: 0.15),
            factor(.styleMatch, 9.4, weight: 0.15),
            factor(.valueForMoney, 8.0, weight: 0.15),
            factor(.budgetFit, 7.8, weight: 0.10),
            factor(.wardrobeGap, 9.0, weight: 0.05),
        ]
        analysis.reasons = AnalysisReasons(
            positive: [
                "You own no flat leather shoe in this colour family",
                "Works with the trousers and skirts you already wear to work",
                "Your history shows shoes at this price get worn for years",
            ],
            negative: ["Sizing on this style runs inconsistent, so returns are likely"],
            keyRisk: "Fit is the only real unknown here.",
            advice: "This fills a genuine gap. Buy the size you can return.",
            uncertainties: ["Brand not confidently identified"]
        )
        return analysis
    }

    /// BYE 51.
    public static var duplicateKnit: Analysis {
        var analysis = leatherJacket
        analysis.analysisId = "fixture-knit"
        analysis.createdAt = .now.addingTimeInterval(-5 * 86_400)
        analysis.product = ProductFacts(
            name: "Ribbed knit top",
            category: .fashion,
            subcategory: "tops",
            price: 89,
            currency: "USD",
            sources: ["price": .confirmed, "category": .confirmed],
            priceConfidence: 0.9,
            identityConfidence: 0.7
        )
        analysis.score = 51
        analysis.verdict = .bye
        analysis.confidence = 0.83
        analysis.confidenceLabel = .high
        analysis.suggestedAction = .skipIt
        analysis.factors = [
            factor(.wardrobeCompatibility, 6.2, weight: 0.25),
            factor(.duplicationRisk, 2.8, weight: 0.15),
            factor(.expectedUsage, 5.5, weight: 0.15),
            factor(.styleMatch, 6.8, weight: 0.15),
            factor(.valueForMoney, 4.5, weight: 0.15),
            factor(.budgetFit, 5.0, weight: 0.10),
            factor(.wardrobeGap, 3.0, weight: 0.05),
        ]
        analysis.reasons = AnalysisReasons(
            positive: ["Black knits are the thing you wear most"],
            negative: [
                "You already own three black ribbed knits",
                "Nothing here does a job your wardrobe is missing",
                "Priced above what you usually pay for a basic top",
            ],
            keyRisk: "This is the fourth version of something you already have.",
            advice: "Skip it. You have better uses for the money.",
            uncertainties: ["Brand not confidently identified"]
        )
        return analysis
    }

    /// The first-analysis case: no wardrobe data, so three factors are excluded
    /// and the copy must not imply knowledge BEFORE does not have (spec §93).
    public static var firstTimeNoWardrobe: Analysis {
        var analysis = leatherJacket
        analysis.analysisId = "fixture-first-time"
        analysis.product = ProductFacts(
            name: "Wool blend coat",
            category: .fashion,
            subcategory: "outerwear",
            price: 240,
            currency: "USD",
            sources: ["price": .confirmed],
            priceConfidence: 0.9,
            identityConfidence: 0.72
        )
        analysis.score = 78
        analysis.verdict = .wait
        analysis.confidence = 0.66
        analysis.confidenceLabel = .medium
        let noWardrobe = "BEFORE does not know your wardrobe well enough yet"
        analysis.factors = [
            factor(.styleMatch, 8.4, weight: 0.273),
            factor(.expectedUsage, 8.0, weight: 0.273),
            factor(.valueForMoney, 7.0, weight: 0.273),
            factor(.budgetFit, 7.6, weight: 0.182),
            factor(.wardrobeCompatibility, 0, weight: 0, included: false, reason: noWardrobe),
            factor(.duplicationRisk, 0, weight: 0, included: false, reason: noWardrobe),
            factor(.wardrobeGap, 0, weight: 0, included: false, reason: noWardrobe),
        ]
        analysis.reasons = AnalysisReasons(
            positive: [
                "Camel outerwear goes with almost any palette",
                "A wool blend coat at this price usually lasts several seasons",
            ],
            negative: ["BEFORE does not know your wardrobe well enough to judge overlap yet"],
            keyRisk: "You may already own something that does this job.",
            advice: "Add a few pieces you own and BEFORE can make a more personal call.",
            uncertainties: [
                "Brand not confidently identified",
                "No wardrobe data, so overlap could not be assessed",
            ]
        )
        return analysis
    }

    public static var recent: [Analysis] { [leatherJacket, loafers, duplicateKnit] }

    public static var profile: UserProfile {
        UserProfile(
            userId: "fixture-user",
            displayName: "Sam Rivera",
            preferredName: nil,
            locale: "en-US",
            currency: "USD",
            timezone: "America/New_York",
            preferences: UserPreferences(
                shoppingPriorities: [.style, .versatility, .quality],
                favoriteStyles: [.minimal, .classic],
                budgetSensitivity: .medium,
                shoppingFocus: .both
            ),
            isPlus: false,
            createdAt: .now.addingTimeInterval(-40 * 86_400)
        )
    }

    public static var usage: UsageSnapshot {
        UsageSnapshot(
            periodStart: .now.addingTimeInterval(-20 * 86_400),
            periodEnd: .now.addingTimeInterval(10 * 86_400),
            used: 1,
            limit: 5,
            remaining: 4,
            isPlus: false
        )
    }
}

// =============================================================================
// Mock repositories
// =============================================================================

public struct MockAnalysisRepository: AnalysisRepositoryProtocol {
    public var delay: Duration
    public var forcedError: APIError?
    private let queue: [Analysis]

    public init(
        queue: [Analysis] = [Fixtures.leatherJacket, Fixtures.loafers, Fixtures.duplicateKnit],
        delay: Duration = .seconds(2),
        forcedError: APIError? = nil
    ) {
        self.queue = queue
        self.delay = delay
        self.forcedError = forcedError
    }

    public func analyse(_ draft: AnalysisRequestDraft) async throws -> Analysis {
        try await Task.sleep(for: delay)
        if let forcedError { throw forcedError }
        // Stable per idempotency key, so a retry returns the same answer.
        let index = abs(draft.idempotencyKey.hashValue) % queue.count
        return queue[index]
    }

    public func analysis(id: String) async throws -> Analysis {
        queue.first { $0.analysisId == id } ?? Fixtures.leatherJacket
    }

    public func recordOutcome(analysisId: String, outcome: OutcomeDraft) async throws {}

    public func usage() async throws -> UsageSnapshot { Fixtures.usage }

    public func explain(analysisId: String, angle: ExplanationAngle) async throws -> String {
        try await Task.sleep(for: .milliseconds(400))
        switch angle {
        case .whyThisVerdict:
            return "The wardrobe overlap is what held this back. Two of the three jackets you own cover the same occasions, so the realistic gain is a third option rather than a new capability."
        case .whatWouldChangeIt:
            return "If this were your first black jacket, or if it came in under your usual outerwear spend, it would clear the bar comfortably."
        case .howItFits:
            return "It works with the neutral trousers and knits you wear most, but so does the moto jacket you already reach for."
        }
    }

    public func productMetadata(for url: String) async throws -> ProductPreview {
        ProductPreview(
            url: url,
            metadata: .init(
                title: "Cropped leather jacket",
                brand: nil,
                price: 198,
                currency: "USD",
                imageUrl: nil,
                retailer: "example.com",
                structured: true
            ),
            cached: false
        )
    }
}

public struct MockProfileRepository: ProfileRepositoryProtocol {
    public init() {}
    public func me() async throws -> UserProfile { Fixtures.profile }
    public func updatePreferences(_ update: ProfileUpdate) async throws -> UserProfile { Fixtures.profile }
    public func deleteAccount() async throws {}
    public func exportData() async throws -> Data {
        Data(#"{"format":"before.export.v1","analyses":[]}"#.utf8)
    }
}

@MainActor
public extension AppEnvironment {
    /// For previews and tests. Never reaches the network.
    static var preview: AppEnvironment {
        AppEnvironment(
            auth: AuthService(),
            subscriptions: SubscriptionManager(),
            analyses: MockAnalysisRepository(delay: .milliseconds(400)),
            profiles: MockProfileRepository(),
            wardrobe: MockWardrobeRepository(),
            sharedInbox: SharedInbox(appGroupIdentifier: AppConfig.appGroupIdentifier),
            notifications: NotificationService(),
            keychain: KeychainStore(service: "com.yourcompany.before.preview")
        )
    }
}
