import XCTest
@testable import BeforeKit

// =============================================================================
// Parity between the Swift engine and the TypeScript engine.
//
// Both load backend/shared/fixtures/score-cases.json. There is no second copy
// of the expectations — if the two implementations drift, exactly one of these
// suites goes red and the difference is visible immediately.
//
// The fixture file is found relative to #filePath rather than bundled as a
// package resource, because it lives outside the package and duplicating it
// would defeat the purpose of a shared suite.
// =============================================================================

final class ScoreParityTests: XCTestCase {

    // MARK: - Fixture loading

    private struct Suite: Decodable {
        let algorithmVersion: String
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let description: String
        let input: Input
        let expected: Expected
    }

    private struct Input: Decodable {
        let signals: AnalysisSignals
        let availability: SignalAvailability
        let context: Context
        let aiConfidence: Double
    }

    private struct Context: Decodable {
        let hasWardrobeData: Bool
        let wardrobeItemCount: Int
        let priceKnown: Bool
        let price: Double?
        let budgetSensitivity: BudgetSensitivity
        let categoryAverageSpend: Double?
        let identityConfidence: Double
    }

    private struct Expected: Decodable {
        let score: Int
        let verdict: Verdict
        let suggestedAction: SuggestedAction
        let confidence: Double
        let confidenceLabel: ConfidenceLabel
        let appliedRules: [String]
        let excludedFactors: [SignalKey]?
    }

    /// repo/ios/BeforeKit/Tests/BeforeKitTests/ThisFile.swift -> repo root
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BeforeKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BeforeKit
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // repo root
    }

    private func loadSuite() throws -> Suite {
        let url = Self.repositoryRoot
            .appendingPathComponent("backend/shared/fixtures/score-cases.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Suite.self, from: data)
    }

    private func engineInput(from input: Input) -> ScoreEngineInput {
        ScoreEngineInput(
            signals: input.signals,
            availability: input.availability,
            context: ScoreContext(
                hasWardrobeData: input.context.hasWardrobeData,
                wardrobeItemCount: input.context.wardrobeItemCount,
                priceKnown: input.context.priceKnown,
                price: input.context.price,
                budgetSensitivity: input.context.budgetSensitivity,
                categoryAverageSpend: input.context.categoryAverageSpend,
                identityConfidence: input.context.identityConfidence
            ),
            aiConfidence: input.aiConfidence
        )
    }

    // MARK: - The shared suite

    func testFixtureSuiteTargetsTheCurrentAlgorithmVersion() throws {
        let suite = try loadSuite()
        XCTAssertEqual(
            suite.algorithmVersion,
            ScoreWeights.algorithmVersion,
            "weights changed without updating the shared fixture suite"
        )
    }

    func testEveryFixtureMatchesTheTypeScriptEngine() throws {
        let suite = try loadSuite()
        XCTAssertFalse(suite.cases.isEmpty, "the fixture suite is empty")

        for testCase in suite.cases {
            let result = PurchaseScoreEngine.score(engineInput(from: testCase.input))

            XCTAssertEqual(result.score, testCase.expected.score, "score — \(testCase.name)")
            XCTAssertEqual(result.verdict, testCase.expected.verdict, "verdict — \(testCase.name)")
            XCTAssertEqual(
                result.suggestedAction,
                testCase.expected.suggestedAction,
                "suggestedAction — \(testCase.name)"
            )
            XCTAssertEqual(
                result.confidence,
                testCase.expected.confidence,
                accuracy: 0.0001,
                "confidence — \(testCase.name)"
            )
            XCTAssertEqual(
                result.confidenceLabel,
                testCase.expected.confidenceLabel,
                "confidenceLabel — \(testCase.name)"
            )

            for rule in testCase.expected.appliedRules {
                XCTAssertTrue(
                    result.appliedRules.contains(rule),
                    "expected rule \(rule) — \(testCase.name), got \(result.appliedRules)"
                )
            }

            for key in testCase.expected.excludedFactors ?? [] {
                let factor = result.factors.first { $0.key == key }
                XCTAssertNotNil(factor, "missing factor \(key) — \(testCase.name)")
                XCTAssertFalse(factor?.included ?? true, "\(key) should be excluded — \(testCase.name)")
                XCTAssertNotNil(
                    factor?.excludedReason,
                    "\(key) must explain why it was excluded — \(testCase.name)"
                )
            }
        }
    }

    // MARK: - Invariants, independent of the fixtures

    func testBaseWeightsSumToOneHundred() {
        let total = SignalKey.allCases.reduce(0.0) { $0 + (ScoreWeights.base[$1] ?? 0) }
        XCTAssertEqual(total, ScoreWeights.totalBaseWeight, accuracy: 0.0001)
    }

    func testEverySignalHasAWeightAndALabel() {
        for key in SignalKey.allCases {
            XCTAssertNotNil(ScoreWeights.base[key], "no weight for \(key)")
            XCTAssertFalse(key.label.isEmpty, "no label for \(key)")
        }
    }

    func testScoreAlwaysStaysWithinRange() {
        for value in stride(from: -50.0, through: 150.0, by: 7) {
            let signals = AnalysisSignals(
                values: Dictionary(uniqueKeysWithValues: SignalKey.allCases.map { ($0, value) })
            )
            let result = PurchaseScoreEngine.score(baseInput(signals: signals))
            XCTAssertTrue((0...100).contains(result.score), "score \(result.score) for signal \(value)")
        }
    }

    func testAllThreeVerdictsRemainReachable() {
        var seen = Set<Verdict>()
        for value in stride(from: 0.0, through: 100.0, by: 5) {
            var signals = AnalysisSignals(
                values: Dictionary(uniqueKeysWithValues: SignalKey.allCases.map { ($0, value) })
            )
            signals[.duplicationRisk] = 100 - value
            seen.insert(PurchaseScoreEngine.score(baseInput(signals: signals)).verdict)
        }
        XCTAssertEqual(seen, Set(Verdict.allCases), "BYE must not become unreachable")
    }

    func testMoreDuplicationNeverRaisesTheScore() {
        var previous = Int.max
        for duplication in stride(from: 0.0, through: 100.0, by: 10) {
            var signals = defaultSignals()
            signals[.duplicationRisk] = duplication
            let score = PurchaseScoreEngine.score(baseInput(signals: signals)).score
            XCTAssertLessThanOrEqual(score, previous, "score rose as duplication reached \(duplication)")
            previous = score
        }
    }

    func testOverridesOnlyEverDowngrade() {
        func severity(_ verdict: Verdict) -> Int {
            switch verdict {
            case .buy: 2
            case .wait: 1
            case .bye: 0
            }
        }
        for duplication in stride(from: 0.0, through: 100.0, by: 5) {
            for gap in stride(from: 0.0, through: 100.0, by: 25) {
                var signals = defaultSignals()
                signals[.duplicationRisk] = duplication
                signals[.wardrobeGap] = gap
                let result = PurchaseScoreEngine.score(baseInput(signals: signals))
                let band = PurchaseScoreEngine.verdict(forScore: result.score)
                XCTAssertLessThanOrEqual(
                    severity(result.verdict),
                    severity(band),
                    "override upgraded \(band) to \(result.verdict) at dup \(duplication) gap \(gap)"
                )
            }
        }
    }

    func testMissingPriceIsNeverPenalisedHarderThanAKnownBadPrice() {
        var signals = defaultSignals()
        signals[.valueForMoney] = 10
        signals[.budgetFit] = 10

        let withPrice = PurchaseScoreEngine.score(baseInput(signals: signals))

        var context = defaultContext()
        context.priceKnown = false
        context.price = nil
        let withoutPrice = PurchaseScoreEngine.score(baseInput(signals: signals, context: context))

        XCTAssertGreaterThanOrEqual(withoutPrice.score, withPrice.score)
    }

    func testNoWardrobeDataLowersConfidenceAndExcludesWardrobeFactors() {
        let known = PurchaseScoreEngine.score(baseInput())

        var context = defaultContext()
        context.hasWardrobeData = false
        context.wardrobeItemCount = 0
        let unknown = PurchaseScoreEngine.score(baseInput(context: context))

        XCTAssertLessThan(unknown.confidence, known.confidence)
        XCTAssertTrue(unknown.appliedRules.contains("no_wardrobe_data"))
        for key in [SignalKey.wardrobeCompatibility, .duplicationRisk, .wardrobeGap] {
            XCTAssertFalse(unknown.factors.first { $0.key == key }?.included ?? true)
        }
    }

    func testIncludedWeightsRenormaliseToOne() {
        var context = defaultContext()
        context.priceKnown = false
        let result = PurchaseScoreEngine.score(baseInput(context: context))
        let total = result.factors.filter(\.included).reduce(0.0) { $0 + $1.weight }
        XCTAssertEqual(total, 1, accuracy: 0.005)
    }

    func testEveryFactorIsReportedIncludedOrNot() {
        var context = defaultContext()
        context.hasWardrobeData = false
        context.priceKnown = false
        let result = PurchaseScoreEngine.score(baseInput(context: context))

        XCTAssertEqual(result.factors.count, SignalKey.allCases.count)
        for factor in result.factors where !factor.included {
            XCTAssertNotNil(factor.excludedReason, "\(factor.key) excluded without a reason")
        }
    }

    func testTheEngineIsDeterministic() {
        let input = baseInput()
        XCTAssertEqual(PurchaseScoreEngine.score(input), PurchaseScoreEngine.score(input))
    }

    func testClampHandlesNaNAndOutOfRange() {
        XCTAssertEqual(PurchaseScoreEngine.clamp(.nan, 0, 100), 0)
        XCTAssertEqual(PurchaseScoreEngine.clamp(-5, 0, 100), 0)
        XCTAssertEqual(PurchaseScoreEngine.clamp(150, 0, 100), 100)
        XCTAssertEqual(PurchaseScoreEngine.clamp(42, 0, 100), 42)
    }

    // MARK: - Helpers

    private func defaultSignals() -> AnalysisSignals {
        AnalysisSignals(values: Dictionary(uniqueKeysWithValues: SignalKey.allCases.map { ($0, 50.0) }))
    }

    private func defaultContext() -> ScoreContext {
        ScoreContext(
            hasWardrobeData: true,
            wardrobeItemCount: 10,
            priceKnown: true,
            price: 100,
            budgetSensitivity: .medium,
            categoryAverageSpend: 100,
            identityConfidence: 0.9
        )
    }

    private func baseInput(
        signals: AnalysisSignals? = nil,
        context: ScoreContext? = nil,
        aiConfidence: Double = 0.9
    ) -> ScoreEngineInput {
        ScoreEngineInput(
            signals: signals ?? defaultSignals(),
            availability: .all,
            context: context ?? defaultContext(),
            aiConfidence: aiConfidence
        )
    }
}
