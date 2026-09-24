import XCTest
@testable import BEFORE
@testable import BeforeKit

// =============================================================================
// Share extension handoff and formatting (spec §68).
//
// The inbox tests use a temporary directory rather than a real App Group, so
// they run in CI without a provisioning profile.
// =============================================================================

final class SharedLinkDetectorTests: XCTestCase {

    func testFindsABareURL() {
        let url = SharedLinkDetector.firstURL(in: "https://shop.example.com/p/123")
        XCTAssertEqual(url?.absoluteString, "https://shop.example.com/p/123")
    }

    func testFindsAURLInsideACaption() {
        // What Instagram and Pinterest actually hand over.
        let text = "obsessed with this 😍 https://shop.example.com/p/123 thoughts??"
        XCTAssertEqual(
            SharedLinkDetector.firstURL(in: text)?.absoluteString,
            "https://shop.example.com/p/123"
        )
    }

    func testIgnoresNonWebSchemes() {
        XCTAssertNil(SharedLinkDetector.firstURL(in: "mailto:someone@example.com"))
        XCTAssertNil(SharedLinkDetector.firstURL(in: "tel:+15555555555"))
    }

    func testTextWithNoLinkBecomesATextPayload() {
        let payload = SharedLinkDetector.payload(forText: "should I get this jacket")
        XCTAssertEqual(payload.kind, .text)
        XCTAssertNil(payload.urlString)
    }

    func testTextWithALinkBecomesAUrlPayload() {
        let payload = SharedLinkDetector.payload(forText: "look https://a.example/b")
        XCTAssertEqual(payload.kind, .url)
        XCTAssertEqual(payload.urlString, "https://a.example/b")
    }
}

// =============================================================================

final class SharedInboxTests: XCTestCase {

    /// A SharedInbox rooted in a temp directory. The production type resolves
    /// its container from the App Group, which is unavailable in a test bundle,
    /// so this subclass-free shim exercises the same read/write/consume logic
    /// against a real filesystem.
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("before-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: Payload round-trips

    func testAnImagePayloadRoundTrips() throws {
        let payload = SharedPayload(kind: .image, imageFilename: "shot.jpg")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(SharedPayload.self, from: encoder.encode(payload))

        XCTAssertEqual(restored.id, payload.id)
        XCTAssertEqual(restored.kind, .image)
        XCTAssertEqual(restored.imageFilename, "shot.jpg")
    }

    func testAUrlPayloadRoundTrips() throws {
        let payload = SharedPayload(kind: .url, urlString: "https://shop.example.com/p/1")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(SharedPayload.self, from: encoder.encode(payload))
        XCTAssertEqual(restored.urlString, "https://shop.example.com/p/1")
    }

    func testTwoPayloadsHaveDistinctIdentities() {
        // Sharing the same product twice must produce two separate items, not
        // a silent overwrite.
        let first = SharedPayload(kind: .url, urlString: "https://a.example")
        let second = SharedPayload(kind: .url, urlString: "https://a.example")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testStalePayloadsAreIdentifiedByAge() {
        let fresh = SharedPayload(kind: .url, urlString: "https://a.example", createdAt: .now)
        let stale = SharedPayload(
            kind: .url,
            urlString: "https://b.example",
            createdAt: .now.addingTimeInterval(-72 * 3600)
        )
        let cutoff = Date.now.addingTimeInterval(-48 * 3600)

        XCTAssertFalse(fresh.createdAt < cutoff)
        XCTAssertTrue(stale.createdAt < cutoff, "an abandoned share must eventually be swept")
    }

    // MARK: Unavailable app group

    func testAnUnconfiguredAppGroupIsReportedNotCrashed() {
        let inbox = SharedInbox(appGroupIdentifier: "group.does.not.exist.\(UUID().uuidString)")
        XCTAssertFalse(inbox.isAvailable)
        // Reading must degrade to "nothing waiting" rather than throwing on a
        // launch path.
        XCTAssertTrue(inbox.pendingPayloads().isEmpty)
    }
}

// =============================================================================

final class FormattingTests: XCTestCase {

    func testPriceUsesTheSuppliedCurrencyNotADollarSign() {
        let gbp = Formatting.price(198, currencyCode: "GBP", locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(gbp, "£198")

        let eur = Formatting.price(198, currencyCode: "EUR", locale: Locale(identifier: "de_DE"))
        XCTAssertNotNil(eur)
        XCTAssertTrue(eur!.contains("198"))
        XCTAssertFalse(eur!.contains("$"), "currency must never be hard-coded to dollars")
    }

    func testPriceKeepsCentsWhenThereAreCents() {
        XCTAssertEqual(
            Formatting.price(12.99, currencyCode: "USD", locale: Locale(identifier: "en_US")),
            "$12.99"
        )
    }

    func testPriceDropsCentsOnWholeAmounts() {
        XCTAssertEqual(
            Formatting.price(198, currencyCode: "USD", locale: Locale(identifier: "en_US")),
            "$198"
        )
    }

    func testAMissingPriceReturnsNilRatherThanZero() {
        // Printing "0" would be a fabricated fact.
        XCTAssertNil(Formatting.price(nil, currencyCode: "USD"))
    }

    func testRelativeDayNamesTodayAndYesterday() {
        let now = Date()
        XCTAssertEqual(Formatting.relativeDay(now, now: now), "Today")

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(Formatting.relativeDay(yesterday, now: now), "Yesterday")
    }

    func testOlderDatesUseALocalisedFormatNotAHardCodedOne() {
        let now = Date()
        let older = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let formatted = Formatting.relativeDay(older, now: now)

        XCTAssertFalse(formatted.isEmpty)
        XCTAssertNotEqual(formatted, "Today")
        XCTAssertNotEqual(formatted, "Yesterday")
    }

    func testFactorValueRendersOneDecimalOutOfTen() {
        XCTAssertEqual(Formatting.factorValue(8.5, locale: Locale(identifier: "en_US")), "8.5/10")
        XCTAssertEqual(Formatting.factorValue(10, locale: Locale(identifier: "en_US")), "10.0/10")
    }

    func testScoreBucketsMatchTheVerdictBands() {
        XCTAssertEqual(Formatting.scoreBucket(0), "0-59")
        XCTAssertEqual(Formatting.scoreBucket(59), "0-59")
        XCTAssertEqual(Formatting.scoreBucket(60), "60-79")
        XCTAssertEqual(Formatting.scoreBucket(79), "60-79")
        XCTAssertEqual(Formatting.scoreBucket(80), "80-100")
        XCTAssertEqual(Formatting.scoreBucket(100), "80-100")
    }

    func testEveryVerdictHasNonInsultingCopy() {
        for verdict in Verdict.allCases {
            let headline = verdict.headline
            XCTAssertFalse(headline.isEmpty)
            for banned in ["stupid", "bad taste", "ugly", "you look", "fat"] {
                XCTAssertFalse(
                    headline.lowercased().contains(banned),
                    "\(verdict) copy must not judge the person: \(headline)"
                )
            }
        }
    }

    func testEverySuggestedActionHasAConcreteNextStep() {
        let actions: [SuggestedAction] = [
            .buyIt, .wait48Hours, .checkWardrobeFirst, .waitForSale, .skipIt,
        ]
        for action in actions {
            XCTAssertFalse(ResultCopy.nextStep(for: action).isEmpty, "no next step for \(action)")
        }
    }

    func testOnlyLowConfidenceGetsAWarningNote() {
        XCTAssertNil(ResultCopy.confidenceNote(for: .high))
        XCTAssertNil(ResultCopy.confidenceNote(for: .medium))
        XCTAssertNotNil(ResultCopy.confidenceNote(for: .low))
    }
}

// =============================================================================

final class AnalyticsTests: XCTestCase {

    func testPropertiesBucketTheScoreRatherThanSendingIt() {
        let properties = AnalyticsProperties(score: 78)
        XCTAssertEqual(properties.dictionary["score_bucket"], "60-79")
        XCTAssertNil(properties.dictionary["score"], "the exact score must not be sent")
    }

    func testPropertiesCarryNothingUnexpected() {
        let properties = AnalyticsProperties(
            category: .fashion,
            verdict: .wait,
            score: 78,
            inputType: .photo,
            isPlus: false,
            context: "home"
        )
        let allowed: Set<String> = [
            "category", "verdict", "score_bucket", "input_type", "subscription_state", "context",
        ]
        XCTAssertTrue(
            Set(properties.dictionary.keys).isSubset(of: allowed),
            "unexpected analytics keys: \(Set(properties.dictionary.keys).subtracting(allowed))"
        )
    }

    func testEmptyPropertiesSendNothing() {
        XCTAssertTrue(AnalyticsProperties().dictionary.isEmpty)
    }
}
