import Foundation

// =============================================================================
// BEFORE — API contract types.
//
// These decode exactly what /v1 sends. They are deliberately permissive about
// things the server may add and strict about the things the UI depends on.
// =============================================================================

public struct ProductFacts: Codable, Sendable, Equatable {
    public var name: String?
    public var brand: String?
    public var category: ProductCategory
    public var subcategory: String?
    public var price: Double?
    public var currency: String?
    public var retailer: String?
    public var material: String?
    public var productUrl: String?
    /// Per-field provenance, keyed by field name. Missing means unknown.
    public var sources: [String: FactSource]
    public var priceConfidence: Double
    public var identityConfidence: Double

    public init(
        name: String? = nil,
        brand: String? = nil,
        category: ProductCategory = .other,
        subcategory: String? = nil,
        price: Double? = nil,
        currency: String? = nil,
        retailer: String? = nil,
        material: String? = nil,
        productUrl: String? = nil,
        sources: [String: FactSource] = [:],
        priceConfidence: Double = 0,
        identityConfidence: Double = 0
    ) {
        self.name = name
        self.brand = brand
        self.category = category
        self.subcategory = subcategory
        self.price = price
        self.currency = currency
        self.retailer = retailer
        self.material = material
        self.productUrl = productUrl
        self.sources = sources
        self.priceConfidence = priceConfidence
        self.identityConfidence = identityConfidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        category = try c.decodeIfPresent(ProductCategory.self, forKey: .category) ?? .other
        subcategory = try c.decodeIfPresent(String.self, forKey: .subcategory)
        price = try c.decodeIfPresent(Double.self, forKey: .price)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        retailer = try c.decodeIfPresent(String.self, forKey: .retailer)
        material = try c.decodeIfPresent(String.self, forKey: .material)
        productUrl = try c.decodeIfPresent(String.self, forKey: .productUrl)
        sources = try c.decodeIfPresent([String: FactSource].self, forKey: .sources) ?? [:]
        priceConfidence = try c.decodeIfPresent(Double.self, forKey: .priceConfidence) ?? 0
        identityConfidence = try c.decodeIfPresent(Double.self, forKey: .identityConfidence) ?? 0
    }

    /// How a given fact was established. Used to pick the right chip.
    public func source(for field: String) -> FactSource {
        sources[field] ?? .unknown
    }

    /// The name to show when the product was not confidently identified.
    /// Never invents one (Rule 5).
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let subcategory, !subcategory.isEmpty { return subcategory.capitalized }
        return "Not confidently identified"
    }
}

public struct VisualAnalysis: Codable, Sendable, Equatable {
    public var colors: [String]
    public var styleTags: [String]
    public var occasionTags: [String]
    public var versatilityEstimate: Double
    public var visualQualityConfidence: Double

    public init(
        colors: [String] = [],
        styleTags: [String] = [],
        occasionTags: [String] = [],
        versatilityEstimate: Double = 0,
        visualQualityConfidence: Double = 0
    ) {
        self.colors = colors
        self.styleTags = styleTags
        self.occasionTags = occasionTags
        self.versatilityEstimate = versatilityEstimate
        self.visualQualityConfidence = visualQualityConfidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colors = try c.decodeIfPresent([String].self, forKey: .colors) ?? []
        styleTags = try c.decodeIfPresent([String].self, forKey: .styleTags) ?? []
        occasionTags = try c.decodeIfPresent([String].self, forKey: .occasionTags) ?? []
        versatilityEstimate = try c.decodeIfPresent(Double.self, forKey: .versatilityEstimate) ?? 0
        visualQualityConfidence = try c.decodeIfPresent(Double.self, forKey: .visualQualityConfidence) ?? 0
    }
}

public struct FactorScore: Codable, Sendable, Equatable, Identifiable {
    public var key: SignalKey
    /// 0...10 as displayed. Already inverted for duplication, so higher is
    /// always better — the same direction as every other row.
    public var value: Double
    public var weight: Double
    public var included: Bool
    public var excludedReason: String?

    public var id: String { key.rawValue }
    /// Preferred over the server's label so the UI stays consistent offline.
    public var label: String { key.label }

    public init(
        key: SignalKey,
        value: Double,
        weight: Double,
        included: Bool,
        excludedReason: String? = nil
    ) {
        self.key = key
        self.value = value
        self.weight = weight
        self.included = included
        self.excludedReason = excludedReason
    }

    private enum CodingKeys: String, CodingKey {
        case key, value, weight, included, excludedReason
    }
}

public struct AnalysisReasons: Codable, Sendable, Equatable {
    public var positive: [String]
    public var negative: [String]
    public var keyRisk: String?
    public var advice: String
    public var uncertainties: [String]

    public init(
        positive: [String] = [],
        negative: [String] = [],
        keyRisk: String? = nil,
        advice: String = "",
        uncertainties: [String] = []
    ) {
        self.positive = positive
        self.negative = negative
        self.keyRisk = keyRisk
        self.advice = advice
        self.uncertainties = uncertainties
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positive = try c.decodeIfPresent([String].self, forKey: .positive) ?? []
        negative = try c.decodeIfPresent([String].self, forKey: .negative) ?? []
        keyRisk = try c.decodeIfPresent(String.self, forKey: .keyRisk)
        advice = try c.decodeIfPresent(String.self, forKey: .advice) ?? ""
        uncertainties = try c.decodeIfPresent([String].self, forKey: .uncertainties) ?? []
    }
}

public struct Analysis: Codable, Sendable, Equatable, Identifiable {
    public var analysisId: String
    public var status: AnalysisStatus
    public var createdAt: Date
    public var product: ProductFacts
    public var visual: VisualAnalysis
    public var score: Int
    public var verdict: Verdict
    public var confidence: Double
    public var confidenceLabel: ConfidenceLabel
    public var factors: [FactorScore]
    public var reasons: AnalysisReasons
    public var suggestedAction: SuggestedAction
    public var imageUrl: String?
    public var promptVersion: String
    public var scoreAlgorithmVersion: String

    public var id: String { analysisId }

    /// Factors in a stable display order, weightiest first, excluded last —
    /// so the result screen never reshuffles between two identical analyses.
    public var orderedFactors: [FactorScore] {
        factors.sorted { lhs, rhs in
            if lhs.included != rhs.included { return lhs.included }
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            return lhs.key.rawValue < rhs.key.rawValue
        }
    }

    public var excludedFactors: [FactorScore] { factors.filter { !$0.included } }

    /// True when BEFORE could not judge the wardrobe — the result screen says
    /// so rather than implying knowledge it does not have (spec §93).
    public var lacksWardrobeContext: Bool {
        factors.contains { $0.key == .wardrobeCompatibility && !$0.included }
    }

    public init(
        analysisId: String,
        status: AnalysisStatus,
        createdAt: Date,
        product: ProductFacts,
        visual: VisualAnalysis,
        score: Int,
        verdict: Verdict,
        confidence: Double,
        confidenceLabel: ConfidenceLabel,
        factors: [FactorScore],
        reasons: AnalysisReasons,
        suggestedAction: SuggestedAction,
        imageUrl: String? = nil,
        promptVersion: String = "",
        scoreAlgorithmVersion: String = ""
    ) {
        self.analysisId = analysisId
        self.status = status
        self.createdAt = createdAt
        self.product = product
        self.visual = visual
        self.score = score
        self.verdict = verdict
        self.confidence = confidence
        self.confidenceLabel = confidenceLabel
        self.factors = factors
        self.reasons = reasons
        self.suggestedAction = suggestedAction
        self.imageUrl = imageUrl
        self.promptVersion = promptVersion
        self.scoreAlgorithmVersion = scoreAlgorithmVersion
    }
}

// -----------------------------------------------------------------------------
// Usage and profile
// -----------------------------------------------------------------------------

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var periodStart: Date
    public var periodEnd: Date
    public var used: Int
    /// nil means no monthly cap (Plus).
    public var limit: Int?
    public var remaining: Int?
    public var isPlus: Bool

    public init(
        periodStart: Date,
        periodEnd: Date,
        used: Int,
        limit: Int?,
        remaining: Int?,
        isPlus: Bool
    ) {
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.isPlus = isPlus
    }

    /// "4 of 5 checks remaining". nil for Plus, which has no number to show.
    public var remainingDescription: String? {
        guard let remaining, let limit else { return nil }
        return "\(remaining) of \(limit) checks remaining"
    }

    public var hasChecksLeft: Bool { isPlus || (remaining ?? 0) > 0 }
}

public struct UserPreferences: Codable, Sendable, Equatable {
    public var shoppingPriorities: [ShoppingPriority]
    public var favoriteStyles: [StylePreference]
    public var budgetSensitivity: BudgetSensitivity
    public var shoppingFocus: ShoppingFocus

    public init(
        shoppingPriorities: [ShoppingPriority] = [],
        favoriteStyles: [StylePreference] = [],
        budgetSensitivity: BudgetSensitivity = .medium,
        shoppingFocus: ShoppingFocus = .both
    ) {
        self.shoppingPriorities = shoppingPriorities
        self.favoriteStyles = favoriteStyles
        self.budgetSensitivity = budgetSensitivity
        self.shoppingFocus = shoppingFocus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown values are dropped rather than failing the whole profile: a
        // server that adds a style must not lock an older app out of its own
        // preferences screen.
        let priorities = try c.decodeIfPresent([String].self, forKey: .shoppingPriorities) ?? []
        shoppingPriorities = priorities.compactMap(ShoppingPriority.init(rawValue:))
        let styles = try c.decodeIfPresent([String].self, forKey: .favoriteStyles) ?? []
        favoriteStyles = styles.compactMap(StylePreference.init(rawValue:))
        budgetSensitivity = try c.decodeIfPresent(BudgetSensitivity.self, forKey: .budgetSensitivity) ?? .medium
        shoppingFocus = try c.decodeIfPresent(ShoppingFocus.self, forKey: .shoppingFocus) ?? .both
    }
}

public struct UserProfile: Codable, Sendable, Equatable {
    public var userId: String
    public var displayName: String?
    public var preferredName: String?
    public var locale: String
    public var currency: String
    public var timezone: String
    public var preferences: UserPreferences
    public var isPlus: Bool
    public var createdAt: Date

    public init(
        userId: String,
        displayName: String? = nil,
        preferredName: String? = nil,
        locale: String = "en-US",
        currency: String = "USD",
        timezone: String = "UTC",
        preferences: UserPreferences = UserPreferences(),
        isPlus: Bool = false,
        createdAt: Date = .now
    ) {
        self.userId = userId
        self.displayName = displayName
        self.preferredName = preferredName
        self.locale = locale
        self.currency = currency
        self.timezone = timezone
        self.preferences = preferences
        self.isPlus = isPlus
        self.createdAt = createdAt
    }

    /// What to call the user. Falls back to nothing rather than "there".
    public var greetingName: String? {
        if let preferredName, !preferredName.isEmpty { return preferredName }
        guard let displayName, !displayName.isEmpty else { return nil }
        return displayName.split(separator: " ").first.map(String.init)
    }
}

// -----------------------------------------------------------------------------
// Errors
// -----------------------------------------------------------------------------

public struct APIErrorBody: Codable, Sendable, Equatable {
    public struct Payload: Codable, Sendable, Equatable {
        public var code: String
        public var message: String
        public var requestId: String
        public var retryAfterSeconds: Int?
    }

    public var error: Payload
}
