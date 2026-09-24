import XCTest
@testable import BEFORE
@testable import BeforeKit

// =============================================================================
// Decoding the /v1 contract (spec §68).
//
// The cases that matter are the tolerant ones: a server that adds a category or
// a style must not break an app already on someone's phone.
// =============================================================================

final class ModelDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSON.decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: Analysis

    func testDecodesAFullAnalysis() throws {
        let analysis = try decode(Analysis.self, Self.analysisJSON)

        XCTAssertEqual(analysis.analysisId, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(analysis.verdict, .wait)
        XCTAssertEqual(analysis.score, 78)
        XCTAssertEqual(analysis.confidenceLabel, .medium)
        XCTAssertEqual(analysis.product.price, 198)
        XCTAssertEqual(analysis.product.currency, "USD")
        XCTAssertEqual(analysis.suggestedAction, .wait48Hours)
        XCTAssertEqual(analysis.factors.count, 7)
        XCTAssertEqual(analysis.reasons.positive.count, 2)
        XCTAssertEqual(analysis.scoreAlgorithmVersion, "score_v1")
    }

    func testDecodesTimestampsWithAndWithoutFractionalSeconds() throws {
        // Postgres sends fractional seconds; the plain ISO8601 strategy rejects
        // them, which would break every date in the app.
        for timestamp in ["2026-09-24T10:30:00Z", "2026-09-24T10:30:00.123456Z"] {
            let json = Self.analysisJSON.replacingOccurrences(
                of: "2026-09-24T10:30:00Z",
                with: timestamp
            )
            XCTAssertNoThrow(try decode(Analysis.self, json), "failed on \(timestamp)")
        }
    }

    func testAnUnknownCategoryDecodesAsOtherRatherThanFailing() throws {
        let json = Self.analysisJSON.replacingOccurrences(of: "\"fashion\"", with: "\"spacesuit\"")
        let analysis = try decode(Analysis.self, json)
        XCTAssertEqual(analysis.product.category, .other)
    }

    func testAnUnknownFactSourceDecodesAsUnknown() throws {
        let json = Self.analysisJSON.replacingOccurrences(of: "\"confirmed\"", with: "\"vibes\"")
        let analysis = try decode(Analysis.self, json)
        XCTAssertEqual(analysis.product.source(for: "price"), .unknown)
    }

    func testMissingOptionalProductFieldsDecodeAsNil() throws {
        let analysis = try decode(Analysis.self, Self.minimalAnalysisJSON)
        XCTAssertNil(analysis.product.name)
        XCTAssertNil(analysis.product.price)
        XCTAssertNil(analysis.product.brand)
        XCTAssertTrue(analysis.reasons.positive.isEmpty)
        XCTAssertEqual(analysis.reasons.advice, "")
    }

    // MARK: Display behaviour that depends on decoding

    func testDisplayNameNeverInventsAProductName() throws {
        let analysis = try decode(Analysis.self, Self.minimalAnalysisJSON)
        XCTAssertEqual(
            analysis.product.displayName,
            "Not confidently identified",
            "Rule 5: BEFORE must not invent a product name"
        )
    }

    func testExcludedFactorsAreDetectedForTheNoWardrobeCopy() throws {
        let analysis = try decode(Analysis.self, Self.noWardrobeAnalysisJSON)
        XCTAssertTrue(analysis.lacksWardrobeContext)
        XCTAssertEqual(analysis.excludedFactors.count, 3)
        XCTAssertEqual(
            ResultCopy.basis(for: analysis),
            "Based on your style and what you've told BEFORE so far.",
            "with no wardrobe, the copy must not claim to know what they own"
        )
    }

    func testOrderedFactorsPutIncludedFirstAndAreStable() throws {
        let analysis = try decode(Analysis.self, Self.noWardrobeAnalysisJSON)
        let ordered = analysis.orderedFactors

        let firstExcluded = ordered.firstIndex { !$0.included } ?? ordered.count
        let lastIncluded = ordered.lastIndex { $0.included } ?? -1
        XCTAssertLessThan(lastIncluded, firstExcluded, "included factors must come first")

        XCTAssertEqual(ordered.map(\.id), analysis.orderedFactors.map(\.id), "ordering must be stable")
    }

    // MARK: Profile

    func testUnknownPreferenceValuesAreDroppedNotFatal() throws {
        let json = """
        {
          "userId": "u1",
          "displayName": "Sam Rivera",
          "preferredName": null,
          "locale": "en-GB",
          "currency": "GBP",
          "timezone": "Europe/London",
          "preferences": {
            "shoppingPriorities": ["style", "telepathy", "value"],
            "favoriteStyles": ["minimal", "cyberpunk"],
            "budgetSensitivity": "high",
            "shoppingFocus": "fashion"
          },
          "isPlus": true,
          "createdAt": "2026-01-01T00:00:00Z"
        }
        """

        let profile = try decode(UserProfile.self, json)
        XCTAssertEqual(profile.preferences.shoppingPriorities, [.style])
        XCTAssertEqual(profile.preferences.favoriteStyles, [.minimal])
        XCTAssertEqual(profile.preferences.budgetSensitivity, .high)
        XCTAssertTrue(profile.isPlus)
        XCTAssertEqual(profile.greetingName, "Sam")
    }

    func testUsageDescriptionIsNilForPlus() throws {
        let plus = UsageSnapshot(
            periodStart: .now, periodEnd: .now, used: 42, limit: nil, remaining: nil, isPlus: true
        )
        XCTAssertNil(plus.remainingDescription)
        XCTAssertTrue(plus.hasChecksLeft)

        let free = UsageSnapshot(
            periodStart: .now, periodEnd: .now, used: 5, limit: 5, remaining: 0, isPlus: false
        )
        XCTAssertEqual(free.remainingDescription, "0 of 5 checks remaining")
        XCTAssertFalse(free.hasChecksLeft)
    }

    // MARK: Fixtures

    private static let analysisJSON = """
    {
      "analysisId": "11111111-2222-3333-4444-555555555555",
      "status": "completed",
      "createdAt": "2026-09-24T10:30:00Z",
      "product": {
        "name": "Cropped leather jacket",
        "brand": null,
        "category": "fashion",
        "subcategory": "outerwear",
        "price": 198,
        "currency": "USD",
        "retailer": null,
        "material": "Leather",
        "productUrl": null,
        "sources": { "price": "confirmed", "brand": "unknown" },
        "priceConfidence": 0.95,
        "identityConfidence": 0.6
      },
      "visual": {
        "colors": ["black"],
        "styleTags": ["minimal"],
        "occasionTags": ["everyday"],
        "versatilityEstimate": 84,
        "visualQualityConfidence": 0.7
      },
      "score": 78,
      "verdict": "WAIT",
      "confidence": 0.74,
      "confidenceLabel": "medium",
      "factors": [
        { "key": "wardrobe_compatibility", "value": 9.0, "weight": 0.25, "included": true, "excludedReason": null },
        { "key": "duplication_risk", "value": 4.8, "weight": 0.15, "included": true, "excludedReason": null },
        { "key": "expected_usage", "value": 8.8, "weight": 0.15, "included": true, "excludedReason": null },
        { "key": "style_match", "value": 9.3, "weight": 0.15, "included": true, "excludedReason": null },
        { "key": "value_for_money", "value": 7.4, "weight": 0.15, "included": true, "excludedReason": null },
        { "key": "budget_fit", "value": 7.2, "weight": 0.10, "included": true, "excludedReason": null },
        { "key": "wardrobe_gap", "value": 6.6, "weight": 0.05, "included": true, "excludedReason": null }
      ],
      "reasons": {
        "positive": ["Works with your neutrals", "High expected usage"],
        "negative": ["You own two similar pieces"],
        "keyRisk": "It overlaps with a jacket you already reach for.",
        "advice": "Wait 48 hours.",
        "uncertainties": ["Brand not confidently identified"]
      },
      "suggestedAction": "WAIT_48_HOURS",
      "imageUrl": null,
      "promptVersion": "purchase_analysis_v1",
      "scoreAlgorithmVersion": "score_v1"
    }
    """

    private static let minimalAnalysisJSON = """
    {
      "analysisId": "a",
      "status": "completed",
      "createdAt": "2026-09-24T10:30:00Z",
      "product": { "category": "other", "sources": {} },
      "visual": {},
      "score": 60,
      "verdict": "WAIT",
      "confidence": 0.5,
      "confidenceLabel": "medium",
      "factors": [],
      "reasons": {},
      "suggestedAction": "WAIT_48_HOURS",
      "promptVersion": "purchase_analysis_v1",
      "scoreAlgorithmVersion": "score_v1"
    }
    """

    private static let noWardrobeAnalysisJSON = """
    {
      "analysisId": "b",
      "status": "completed",
      "createdAt": "2026-09-24T10:30:00Z",
      "product": { "category": "fashion", "sources": {} },
      "visual": {},
      "score": 78,
      "verdict": "WAIT",
      "confidence": 0.66,
      "confidenceLabel": "medium",
      "factors": [
        { "key": "style_match", "value": 8.4, "weight": 0.273, "included": true, "excludedReason": null },
        { "key": "expected_usage", "value": 8.0, "weight": 0.273, "included": true, "excludedReason": null },
        { "key": "value_for_money", "value": 7.0, "weight": 0.273, "included": true, "excludedReason": null },
        { "key": "budget_fit", "value": 7.6, "weight": 0.182, "included": true, "excludedReason": null },
        { "key": "wardrobe_compatibility", "value": 0, "weight": 0, "included": false, "excludedReason": "BEFORE does not know your wardrobe well enough yet" },
        { "key": "duplication_risk", "value": 0, "weight": 0, "included": false, "excludedReason": "BEFORE does not know your wardrobe well enough yet" },
        { "key": "wardrobe_gap", "value": 0, "weight": 0, "included": false, "excludedReason": "BEFORE does not know your wardrobe well enough yet" }
      ],
      "reasons": {},
      "suggestedAction": "WAIT_48_HOURS",
      "promptVersion": "purchase_analysis_v1",
      "scoreAlgorithmVersion": "score_v1"
    }
    """
}
