import Foundation

// =============================================================================
// BEFORE — PurchaseScoreEngine (Swift mirror).
//
// Line-for-line equivalent of backend/shared/scoring/engine.ts. Both run the
// fixture suite in backend/shared/fixtures/score-cases.json, so a divergence
// fails the build rather than reaching a user as a number that disagrees with
// the one the server stored.
//
// Rounding is spelled out explicitly here for the same reason: rounding is
// where two implementations of the same formula usually start to differ.
// =============================================================================

public struct ScoreContext: Sendable, Equatable {
    public var hasWardrobeData: Bool
    public var wardrobeItemCount: Int
    public var priceKnown: Bool
    public var price: Double?
    public var budgetSensitivity: BudgetSensitivity
    /// The user's own median spend in this category. nil until enough history.
    public var categoryAverageSpend: Double?
    public var identityConfidence: Double

    public init(
        hasWardrobeData: Bool,
        wardrobeItemCount: Int,
        priceKnown: Bool,
        price: Double?,
        budgetSensitivity: BudgetSensitivity,
        categoryAverageSpend: Double?,
        identityConfidence: Double
    ) {
        self.hasWardrobeData = hasWardrobeData
        self.wardrobeItemCount = wardrobeItemCount
        self.priceKnown = priceKnown
        self.price = price
        self.budgetSensitivity = budgetSensitivity
        self.categoryAverageSpend = categoryAverageSpend
        self.identityConfidence = identityConfidence
    }
}

public struct ScoreEngineInput: Sendable {
    public var signals: AnalysisSignals
    public var availability: SignalAvailability
    public var context: ScoreContext
    public var aiConfidence: Double

    public init(
        signals: AnalysisSignals,
        availability: SignalAvailability,
        context: ScoreContext,
        aiConfidence: Double
    ) {
        self.signals = signals
        self.availability = availability
        self.context = context
        self.aiConfidence = aiConfidence
    }
}

public struct ScoreResult: Sendable, Equatable {
    public var score: Int
    public var verdict: Verdict
    public var suggestedAction: SuggestedAction
    public var confidence: Double
    public var confidenceLabel: ConfidenceLabel
    public var factors: [FactorScore]
    /// Ordered audit trail of the deterministic rules that fired.
    public var appliedRules: [String]
    public var algorithmVersion: String
}

public enum PurchaseScoreEngine {
    public static let version = ScoreWeights.algorithmVersion

    // MARK: - Exclusion reasons (must match engine.ts)

    enum ExclusionReason {
        static let noWardrobe = "BEFORE does not know your wardrobe well enough yet"
        static let noPrice = "Price was not confidently identified"
        static let notAssessable = "Not enough information in the image to judge this"
    }

    private static let wardrobeDependent: [SignalKey] = [
        .wardrobeCompatibility, .duplicationRisk, .wardrobeGap,
    ]
    private static let priceDependent: [SignalKey] = [.valueForMoney, .budgetFit]

    // MARK: - Entry point

    public static func score(_ input: ScoreEngineInput) -> ScoreResult {
        var appliedRules: [String] = []
        let (available, reasons) = resolveAvailability(input, appliedRules: &appliedRules)

        // 1. Effective weights: included signals only, renormalised to sum to 1.
        var includedWeight: Double = 0
        for key in SignalKey.allCases where available[key] {
            includedWeight += ScoreWeights.base[key] ?? 0
        }

        // Degenerate case: nothing is knowable. Refuse to produce a verdict that
        // pretends otherwise.
        guard includedWeight > 0 else {
            appliedRules.append("no_assessable_signals")
            return ScoreResult(
                score: 0,
                verdict: .wait,
                suggestedAction: .wait48Hours,
                confidence: 0,
                confidenceLabel: .low,
                factors: SignalKey.allCases.map { key in
                    FactorScore(
                        key: key,
                        value: 0,
                        weight: 0,
                        included: false,
                        excludedReason: reasons[key] ?? ExclusionReason.notAssessable
                    )
                },
                appliedRules: appliedRules,
                algorithmVersion: ScoreWeights.algorithmVersion
            )
        }

        // 2. Weighted sum. Inverse signals contribute (100 - value).
        var raw: Double = 0
        var factors: [FactorScore] = []

        for key in SignalKey.allCases {
            let rawValue = clamp(input.signals[key], 0, 100)
            let contribution = ScoreWeights.inverseSignals.contains(key) ? 100 - rawValue : rawValue
            let included = available[key]
            let effectiveWeight = included ? (ScoreWeights.base[key] ?? 0) / includedWeight : 0

            if included { raw += contribution * effectiveWeight }

            factors.append(
                FactorScore(
                    key: key,
                    // Displayed as x/10. Inverse signals display their
                    // CONTRIBUTION, so a high "Duplication" number always reads
                    // as good, like every other row.
                    value: round1(contribution / 10),
                    weight: round3(effectiveWeight),
                    included: included,
                    excludedReason: included ? nil : (reasons[key] ?? ExclusionReason.notAssessable)
                )
            )
        }

        let score = Int(clamp(raw, 0, 100).rounded())

        // 3. Confidence: the model's own, discounted by how much of the picture
        //    we actually had and how sure we are what the product even is.
        let coverage = includedWeight / ScoreWeights.totalBaseWeight
        let identity = clamp(input.context.identityConfidence, 0, 1)
        let confidence = round2(
            clamp(
                clamp(input.aiConfidence, 0, 1) * (0.55 + 0.45 * coverage) * (0.75 + 0.25 * identity),
                0,
                1
            )
        )

        // 4. Verdict, then deterministic overrides (downgrade-only).
        let bandVerdict = verdict(forScore: score)
        let finalVerdict = applyOverrides(
            bandVerdict,
            input: input,
            available: available,
            confidence: confidence,
            appliedRules: &appliedRules
        )

        return ScoreResult(
            score: score,
            verdict: finalVerdict,
            suggestedAction: suggestedAction(for: finalVerdict, appliedRules: appliedRules),
            confidence: confidence,
            confidenceLabel: confidenceLabel(for: confidence),
            factors: factors,
            appliedRules: appliedRules,
            algorithmVersion: ScoreWeights.algorithmVersion
        )
    }

    // MARK: - Availability

    private static func resolveAvailability(
        _ input: ScoreEngineInput,
        appliedRules: inout [String]
    ) -> (SignalAvailability, [SignalKey: String]) {
        var available = input.availability
        var reasons: [SignalKey: String] = [:]

        for key in SignalKey.allCases where !available[key] {
            reasons[key] = ExclusionReason.notAssessable
        }

        if !input.context.hasWardrobeData {
            appliedRules.append("no_wardrobe_data")
            for key in wardrobeDependent {
                available[key] = false
                reasons[key] = ExclusionReason.noWardrobe
            }
        }

        if !input.context.priceKnown {
            appliedRules.append("price_unknown_no_price_penalty")
            for key in priceDependent {
                available[key] = false
                reasons[key] = ExclusionReason.noPrice
            }
        }

        return (available, reasons)
    }

    // MARK: - Overrides

    /// Overrides may only make a verdict MORE conservative, never less. That
    /// invariant is what keeps the product honest when one signal is extreme
    /// but the weighted average is bland.
    private static func applyOverrides(
        _ verdict: Verdict,
        input: ScoreEngineInput,
        available: SignalAvailability,
        confidence: Double,
        appliedRules: inout [String]
    ) -> Verdict {
        var result = verdict
        let context = input.context

        // R1 — you already own this.
        if context.hasWardrobeData, available[.duplicationRisk], available[.wardrobeGap] {
            let duplication = clamp(input.signals[.duplicationRisk], 0, 100)
            let gap = clamp(input.signals[.wardrobeGap], 0, 100)

            if duplication >= ScoreWeights.Override.duplicationByeRisk,
               gap <= ScoreWeights.Override.duplicationByeGap {
                result = cap(result, at: .bye)
                appliedRules.append("duplication_dominant_bye")
            } else if duplication >= ScoreWeights.Override.duplicationWaitRisk,
                      gap <= ScoreWeights.Override.duplicationWaitGap {
                result = cap(result, at: .wait)
                appliedRules.append("duplication_dominant_wait")
            }
        }

        // R2 — well above what this user normally spends in this category.
        if context.priceKnown,
           let price = context.price,
           let average = context.categoryAverageSpend,
           average > 0,
           context.budgetSensitivity == .high,
           price > average * ScoreWeights.Override.expensiveForBudgetMultiple {
            result = cap(result, at: .wait)
            appliedRules.append("expensive_for_budget")
        }

        // R3 — BEFORE does not tell someone to spend money it is not sure about.
        if result == .buy, confidence < ScoreWeights.Override.minConfidenceForBuy {
            result = cap(result, at: .wait)
            appliedRules.append("low_confidence_demotes_buy")
        }

        return result
    }

    private static func severity(_ verdict: Verdict) -> Int {
        switch verdict {
        case .buy: 2
        case .wait: 1
        case .bye: 0
        }
    }

    private static func cap(_ current: Verdict, at ceiling: Verdict) -> Verdict {
        severity(ceiling) < severity(current) ? ceiling : current
    }

    private static func suggestedAction(for verdict: Verdict, appliedRules: [String]) -> SuggestedAction {
        switch verdict {
        case .buy: return .buyIt
        case .bye: return .skipIt
        case .wait:
            if appliedRules.contains("duplication_dominant_wait") { return .checkWardrobeFirst }
            if appliedRules.contains("expensive_for_budget") { return .waitForSale }
            return .wait48Hours
        }
    }

    // MARK: - Public helpers

    public static func verdict(forScore score: Int) -> Verdict {
        if score >= ScoreWeights.Threshold.buy { return .buy }
        if score >= ScoreWeights.Threshold.wait { return .wait }
        return .bye
    }

    public static func confidenceLabel(for confidence: Double) -> ConfidenceLabel {
        if confidence >= ScoreWeights.ConfidenceBand.high { return .high }
        if confidence >= ScoreWeights.ConfidenceBand.medium { return .medium }
        return .low
    }

    // MARK: - Rounding
    //
    // Spelled out so it can be compared against the TypeScript character by
    // character. JavaScript's Math.round and Swift's .rounded() agree on
    // non-negative values, which is all this engine ever handles.

    static func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        if value.isNaN { return minimum }
        return Swift.min(maximum, Swift.max(minimum, value))
    }

    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
    static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
