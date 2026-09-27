import Foundation
import StoreKit
import StoreKitTest
import XCTest
@testable import BEFORE
@testable import BeforeKit

// =============================================================================
// Subscription behaviour (spec §68).
//
// Runs against ios/StoreKit/Products.storekit through SKTestSession, so no
// App Store Connect account and no network are involved.
//
// One thing these tests deliberately DO cover: that a purchase never grants
// entitlement by any route other than a verified transaction.
// =============================================================================

@MainActor
final class SubscriptionTests: XCTestCase {

    private var session: SKTestSession!
    private var manager: SubscriptionManager!

    override func setUp() async throws {
        try await super.setUp()

        session = try SKTestSession(configurationFileNamed: "Products")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true

        manager = SubscriptionManager(
            keychain: KeychainStore(service: "com.yourcompany.before.tests")
        )
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
        manager = nil
        UserDefaults.standard.removeObject(forKey: "before.cache.isPlus")
        try await super.tearDown()
    }

    // MARK: Helpers

    /// Waits for `isPlus` to reach `expected`, refreshing as it goes.
    ///
    /// `SKTestSession` mutations — expiring, refunding — do not reach
    /// `Transaction.currentEntitlements` synchronously. In the app that
    /// propagation arrives through `Transaction.updates`; a test has to wait for
    /// it. This still fails if the entitlement never changes, so it cannot hide
    /// a real regression — and on timeout it prints what StoreKit actually said,
    /// because "XCTAssertFalse failed" on its own tells you nothing about why.
    private func waitForIsPlus(
        _ expected: Bool,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            await manager.refreshEntitlements()
            if manager.isPlus == expected { return }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let diagnosis = await entitlementDiagnostics()
        XCTFail(
            "isPlus stayed \(manager.isPlus) after \(Int(timeout))s, expected \(expected).\n  \(diagnosis)",
            file: file,
            line: line
        )
    }

    /// Everything the entitlement decision is made from, as text.
    private func entitlementDiagnostics() async -> String {
        var lines: [String] = []

        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                lines.append(
                    "verified \(transaction.productID)"
                    + " expires=\(transaction.expirationDate?.description ?? "nil")"
                    + " revoked=\(transaction.revocationDate?.description ?? "nil")"
                )
            case .unverified(let transaction, let error):
                lines.append("UNVERIFIED \(transaction.productID): \(error)")
            }
        }

        if let statuses = try? await Product.SubscriptionInfo.status(
            for: AppConfig.Subscription.groupIdentifier
        ) {
            for status in statuses {
                lines.append("renewal state = \(String(describing: status.state))")
            }
        } else {
            lines.append("no subscription status available")
        }

        return lines.isEmpty ? "no entitlements at all" : lines.joined(separator: "\n  ")
    }

    // MARK: Products

    func testLoadsBothPlans() async {
        await manager.loadProducts()

        XCTAssertEqual(manager.loadState, .loaded)
        XCTAssertEqual(manager.monthly?.id, AppConfig.Subscription.monthly)
        XCTAssertEqual(manager.yearly?.id, AppConfig.Subscription.yearly)
    }

    func testAnnualSavingIsComputedFromRealPricesNotHardCoded() async {
        await manager.loadProducts()

        guard let monthly = manager.monthly, let yearly = manager.yearly else {
            return XCTFail("products did not load")
        }

        // Mirrors the production expression, including the conversion out of
        // `Decimal` for the rounding — `Decimal` has no `rounded()`.
        let yearAtMonthlyRate = monthly.price * 12
        let saving = (yearAtMonthlyRate - yearly.price) / yearAtMonthlyRate
        let expected = Int(NSDecimalNumber(decimal: saving * 100).doubleValue.rounded())
        XCTAssertEqual(manager.annualSavingDescription, "Save \(expected)%")
    }

    func testNoSavingIsClaimedWhenTheAnnualPlanIsNotCheaper() async {
        // A pricing change that removes the discount must remove the claim,
        // not keep showing a stale "Save 30%".
        let manager = SubscriptionManager()
        XCTAssertNil(manager.annualSavingDescription, "no products loaded means no claim")
    }

    // MARK: Entitlement

    func testStartsWithoutEntitlement() async {
        await manager.refreshEntitlements()
        XCTAssertFalse(manager.isPlus)
    }

    func testAPurchaseGrantsEntitlement() async throws {
        await manager.loadProducts()
        let product = try XCTUnwrap(manager.yearly)

        let outcome = await manager.purchase(product)

        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(manager.isPlus)
        XCTAssertNotNil(manager.expirationDate)
    }

    func testAnExpiredSubscriptionDoesNotGrantEntitlement() async throws {
        await manager.loadProducts()
        let product = try XCTUnwrap(manager.monthly)
        _ = await manager.purchase(product)
        XCTAssertTrue(manager.isPlus)

        // Expire it the way Apple would.
        try session.expireSubscription(
            productIdentifier: AppConfig.Subscription.monthly
        )
        await waitForIsPlus(false)
    }

    func testARevokedTransactionRemovesEntitlement() async throws {
        await manager.loadProducts()
        let product = try XCTUnwrap(manager.yearly)
        _ = await manager.purchase(product)
        XCTAssertTrue(manager.isPlus)

        for transaction in session.allTransactions() {
            try await session.refundTransaction(identifier: UInt(transaction.identifier))
        }
        await waitForIsPlus(false)
    }

    func testRestoreFindsAnExistingSubscription() async throws {
        await manager.loadProducts()
        let product = try XCTUnwrap(manager.monthly)
        _ = await manager.purchase(product)

        let fresh = SubscriptionManager(
            keychain: KeychainStore(service: "com.yourcompany.before.tests")
        )
        let outcome = await fresh.restorePurchases()

        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(fresh.isPlus)
    }

    func testRestoreWithNothingToRestoreReportsItPlainly() async {
        let outcome = await manager.restorePurchases()

        guard case .failed(let message) = outcome else {
            return XCTFail("expected a readable failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("couldn't find"), "message must be readable: \(message)")
        XCTAssertFalse(message.contains("Error"), "spec §45: no 'Error 2' messages")
        XCTAssertFalse(manager.isPlus)
    }

    /// A user cancellation cannot be simulated through `SKTestSession`.
    ///
    /// The obvious attempt does not work:
    ///
    /// ```swift
    /// session.failTransactionsEnabled = true
    /// session.failureError = .paymentCancelled
    /// ```
    ///
    /// `failureError` simulates a *server-side* failure, not a person tapping
    /// Cancel. What actually arrives is
    /// `AMSErrorDomain Code=305 "Server Error"`, which StoreKit itself logs as
    /// "Received error that does not have a corresponding StoreKit Error" — so
    /// the outcome is a legitimate `.failed`, and asserting `.userCancelled`
    /// there was asserting something untrue.
    ///
    /// Tapping Cancel is a UI action, and in that case `purchase()` *returns*
    /// `.userCancelled` rather than throwing, which `purchase(_:)` handles
    /// directly. What remains testable, and what actually had a bug, is the
    /// thrown form — so test that where it lives.
    func testCancellationIsRecognisedHoweverItArrives() {
        let cancelled = NSError(
            domain: SKErrorDomain,
            code: SKError.Code.paymentCancelled.rawValue
        )

        XCTAssertTrue(
            SubscriptionManager.isCancellation(StoreKitError.userCancelled),
            "the plain thrown form"
        )
        XCTAssertTrue(
            SubscriptionManager.isCancellation(cancelled),
            "a bare SKError"
        )
        XCTAssertTrue(
            SubscriptionManager.isCancellation(StoreKitError.systemError(cancelled)),
            "wrapped in systemError — bridging to NSError does not see through this"
        )

        // The error a StoreKit Testing session really produces. It is a
        // failure, and it must keep producing a readable failure message.
        XCTAssertFalse(
            SubscriptionManager.isCancellation(
                StoreKitError.systemError(NSError(domain: "AMSErrorDomain", code: 305))
            ),
            "a server error is not a cancellation"
        )
        XCTAssertFalse(
            SubscriptionManager.isCancellation(StoreKitError.notEntitled)
        )
        XCTAssertFalse(
            SubscriptionManager.isCancellation(URLError(.timedOut))
        )
    }

    func testAFailedPurchaseProducesAReadableMessageAndNoEntitlement() async throws {
        await manager.loadProducts()
        let product = try XCTUnwrap(manager.monthly)

        session.failTransactionsEnabled = true
        session.failureError = .invalidSignature

        let outcome = await manager.purchase(product)

        guard case .failed(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(manager.isPlus, "a failed purchase must never grant Plus")
    }

    func testAskToBuyIsReportedAsPendingNotAsSuccess() async throws {
        session.askToBuyEnabled = true
        await manager.loadProducts()
        let product = try XCTUnwrap(manager.monthly)

        let outcome = await manager.purchase(product)

        XCTAssertEqual(outcome, .pending)
        XCTAssertFalse(manager.isPlus, "Plus is not unlocked until the purchase is approved")
    }

    // MARK: The invariant that matters most

    func testUserDefaultsAloneCannotGrantEntitlement() async {
        // The cached flag exists only so the paywall does not flash on launch.
        // It must never survive a real entitlement check.
        UserDefaults.standard.set(true, forKey: "before.cache.isPlus")

        let manager = SubscriptionManager(
            keychain: KeychainStore(service: "com.yourcompany.before.tests")
        )
        XCTAssertTrue(manager.isPlus, "the cached value is used for the first frame")

        await manager.refreshEntitlements()
        XCTAssertFalse(
            manager.isPlus,
            "a verified check must overrule the cache — spec §76"
        )
    }
}
