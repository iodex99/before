import Foundation

// =============================================================================
// BEFORE — domain model.
//
// Mirrors backend/shared/types.ts. Every enum decodes from the exact strings
// the API sends, and every one of them has an `unknown`-tolerant decoder where
// the server may add cases later: a new category shipped on the server must not
// break an app that is already on someone's phone.
// =============================================================================

public enum Verdict: String, Codable, Sendable, CaseIterable {
    case buy = "BUY"
    case wait = "WAIT"
    case bye = "BYE"

    /// The headline on the result screen (spec §58).
    public var headline: String {
        switch self {
        case .buy: "This makes sense for you."
        case .wait: "Worth pausing on."
        case .bye: "Skip it. You have better uses for the money."
        }
    }

    /// Always rendered alongside the colour — colour never carries meaning
    /// alone (spec §61).
    public var label: String { rawValue }
}

public enum SuggestedAction: String, Codable, Sendable {
    case buyIt = "BUY_IT"
    case wait48Hours = "WAIT_48_HOURS"
    case checkWardrobeFirst = "CHECK_WARDROBE_FIRST"
    case waitForSale = "WAIT_FOR_SALE"
    case skipIt = "SKIP_IT"
}

public enum ProductCategory: String, Codable, Sendable, CaseIterable {
    case fashion, beauty, accessory, home, travel, gift, other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProductCategory(rawValue: raw) ?? .other
    }
}

public enum ShoppingPriority: String, Codable, Sendable, CaseIterable, Identifiable {
    case style, price, quality, versatility, longevity, trend, sustainability
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum StylePreference: String, Codable, Sendable, CaseIterable, Identifiable {
    case minimal, classic, feminine, casual, edgy
    case romantic, streetwear, preppy, bohemian, sporty
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum BudgetSensitivity: String, Codable, Sendable, CaseIterable {
    case low, medium, high
}

public enum ShoppingFocus: String, Codable, Sendable, CaseIterable, Identifiable {
    case fashion, beauty, both
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .fashion: "Fashion"
        case .beauty: "Beauty"
        case .both: "Both"
        }
    }
}

public enum InputType: String, Codable, Sendable {
    case photo, camera, screenshot, url
    case shareExtension = "share_extension"
}

public enum OutcomeAction: String, Codable, Sendable, CaseIterable {
    case bought, skipped
    case stillThinking = "still_thinking"

    public var title: String {
        switch self {
        case .bought: "Bought it"
        case .skipped: "Skipped it"
        case .stillThinking: "Still thinking"
        }
    }
}

public enum Satisfaction: String, Codable, Sendable, CaseIterable, Identifiable {
    case loveIt = "love_it"
    case good, fine
    case regretIt = "regret_it"
    case returned

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .loveIt: "Love it"
        case .good: "Good"
        case .fine: "Fine"
        case .regretIt: "Regret it"
        case .returned: "Returned it"
        }
    }
}

public enum SavedBucket: String, Codable, Sendable, CaseIterable, Identifiable {
    case maybe, bought, owned
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .maybe: "Maybe"
        case .bought: "Bought"
        case .owned: "Owned"
        }
    }
}

public enum AnalysisStatus: String, Codable, Sendable {
    case pending, processing, completed, failed
}

public enum ConfidenceLabel: String, Codable, Sendable {
    case low, medium, high
}

/// How a product fact was established. Drives the chips under the product name
/// so an estimate is never shown as a confirmed fact (spec §25, Rule 5).
public enum FactSource: String, Codable, Sendable {
    case confirmed, estimated, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FactSource(rawValue: raw) ?? .unknown
    }
}

// -----------------------------------------------------------------------------
// Signals
// -----------------------------------------------------------------------------

public enum SignalKey: String, Codable, Sendable, CaseIterable, Identifiable {
    case styleMatch = "style_match"
    case wardrobeCompatibility = "wardrobe_compatibility"
    case duplicationRisk = "duplication_risk"
    case expectedUsage = "expected_usage"
    case valueForMoney = "value_for_money"
    case budgetFit = "budget_fit"
    case wardrobeGap = "wardrobe_gap"

    public var id: String { rawValue }

    /// Must match SIGNAL_LABELS in backend/shared/scoring/weights.ts.
    public var label: String {
        switch self {
        case .wardrobeCompatibility: "Wardrobe fit"
        case .duplicationRisk: "Duplication"
        case .expectedUsage: "Versatility"
        case .styleMatch: "Style match"
        case .valueForMoney: "Value"
        case .budgetFit: "Budget fit"
        case .wardrobeGap: "Fills a gap"
        }
    }
}

public struct AnalysisSignals: Codable, Sendable, Equatable {
    public var values: [SignalKey: Double]

    public init(values: [SignalKey: Double]) { self.values = values }

    public subscript(key: SignalKey) -> Double {
        get { values[key] ?? 0 }
        set { values[key] = newValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RawKey.self)
        var parsed: [SignalKey: Double] = [:]
        for key in SignalKey.allCases {
            guard let codingKey = RawKey(stringValue: key.rawValue) else { continue }
            parsed[key] = try container.decodeIfPresent(Double.self, forKey: codingKey) ?? 0
        }
        values = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RawKey.self)
        for (key, value) in values {
            guard let codingKey = RawKey(stringValue: key.rawValue) else { continue }
            try container.encode(value, forKey: codingKey)
        }
    }
}

public struct SignalAvailability: Codable, Sendable, Equatable {
    public var values: [SignalKey: Bool]

    public init(values: [SignalKey: Bool]) { self.values = values }

    /// Everything knowable. The common case when a wardrobe and a price exist.
    public static var all: SignalAvailability {
        SignalAvailability(values: Dictionary(uniqueKeysWithValues: SignalKey.allCases.map { ($0, true) }))
    }

    public subscript(key: SignalKey) -> Bool {
        get { values[key] ?? false }
        set { values[key] = newValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RawKey.self)
        var parsed: [SignalKey: Bool] = [:]
        for key in SignalKey.allCases {
            guard let codingKey = RawKey(stringValue: key.rawValue) else { continue }
            // Absent means available: an older client must keep working when
            // the server adds a signal it does not know how to opt out of.
            parsed[key] = try container.decodeIfPresent(Bool.self, forKey: codingKey) ?? true
        }
        values = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RawKey.self)
        for (key, value) in values {
            guard let codingKey = RawKey(stringValue: key.rawValue) else { continue }
            try container.encode(value, forKey: codingKey)
        }
    }
}

/// A CodingKey that accepts any string, for the signal dictionaries above.
struct RawKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
