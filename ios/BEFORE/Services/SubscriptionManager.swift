import Foundation
import Observation
import StoreKit
import UIKit
import BeforeKit

// =============================================================================
// BEFORE — StoreKit 2.
//
// The rule that shapes this file: `isPlus` is derived from VERIFIED
// entitlements only (spec §76). There is no UserDefaults flag, no local
// boolean anyone can set, and no path where a failed verification grants
// access. `UserDefaults` caches the last known state purely so the UI does not
// flash "free" for a frame on launch — it never unlocks anything.
// =============================================================================

@MainActor
@Observable
public final class SubscriptionManager {

    public enum PurchaseOutcome: Equatable, Sendable {
        case success
        case userCancelled
        /// Ask to Buy, SCA, or another deferred approval.
        case pending
        case failed(String)
    }

    public enum LoadState: Equatable, Sendable {
        case idle, loading, loaded
        case failed(String)
    }

    // MARK: - Observable state

    public private(set) var monthly: Product?
    public private(set) var yearly: Product?
    public private(set) var loadState: LoadState = .idle
    public private(set) var isPlus: Bool = false
    public private(set) var expirationDate: Date?
    /// True during a billing retry or grace period. The UI mentions it once,
    /// quietly, rather than nagging.
    public private(set) var isInBillingRetry = false
    public private(set) var isRestoring = false
    public private(set) var isPurchasing = false

    // MARK: - Dependencies

    private let keychain: KeychainStore
    private let syncSubscription: @Sendable (SubscriptionSyncPayload) async -> Void
    /// Held in a `TaskHandle` rather than a plain `Task?` so `deinit` can cancel
    /// it: `deinit` is nonisolated under Swift 6 and may not touch main-actor
    /// state. See `BeforeKit.TaskHandle`.
    private let updates = TaskHandle()

    private static let cachedIsPlusKey = "before.cache.isPlus"

    public init(
        keychain: KeychainStore = KeychainStore(),
        syncSubscription: @escaping @Sendable (SubscriptionSyncPayload) async -> Void = { _ in }
    ) {
        self.keychain = keychain
        self.syncSubscription = syncSubscription
        // Display-only cache, so the paywall does not flash for Plus members on
        // a cold launch. Replaced by the verified value moments later.
        isPlus = UserDefaults.standard.bool(forKey: Self.cachedIsPlusKey)
    }

    deinit { updates.cancel() }

    // MARK: - Lifecycle

    /// Start listening for transactions. Called once, at launch, before any UI
    /// needs the answer — a transaction approved outside the app (Ask to Buy,
    /// a renewal) arrives through this stream and nowhere else.
    public func start() {
        guard !updates.isActive else { return }

        updates.store(
            Task(priority: .background) { [weak self] in
                for await update in Transaction.updates {
                    guard let self else { return }
                    await self.handle(update)
                }
            }
        )

        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    // MARK: - Products

    public func loadProducts() async {
        loadState = .loading
        do {
            let products = try await Product.products(for: AppConfig.Subscription.all)
            monthly = products.first { $0.id == AppConfig.Subscription.monthly }
            yearly = products.first { $0.id == AppConfig.Subscription.yearly }

            if monthly == nil && yearly == nil {
                loadState = .failed("We couldn't load subscription options.")
            } else {
                loadState = .loaded
            }
        } catch {
            loadState = .failed("We couldn't load subscription options.")
        }
    }

    // MARK: - Entitlement

    /// The authoritative check. Walks the verified current entitlements.
    public func refreshEntitlements() async {
        var entitled = false
        var latestExpiry: Date?
        var billingRetry = false

        for await result in Transaction.currentEntitlements {
            // An unverified transaction is ignored, not trusted. This is the
            // line that makes the whole model work.
            guard case .verified(let transaction) = result else { continue }
            guard AppConfig.Subscription.all.contains(transaction.productID) else { continue }
            guard transaction.revocationDate == nil else { continue }

            if let expiry = transaction.expirationDate, expiry < .now { continue }

            entitled = true
            if let expiry = transaction.expirationDate {
                latestExpiry = latestExpiry.map { Swift.max($0, expiry) } ?? expiry
            }
        }

        // A grace period or billing retry still counts as entitled: Apple is
        // retrying the charge, and cutting someone off mid-retry is a bad
        // experience for a card that expired.
        if let statuses = try? await Product.SubscriptionInfo.status(
            for: AppConfig.Subscription.groupIdentifier
        ) {
            for status in statuses {
                switch status.state {
                case .inGracePeriod, .inBillingRetryPeriod:
                    entitled = true
                    billingRetry = true
                case .subscribed:
                    entitled = true
                default:
                    break
                }
            }
        }

        isPlus = entitled
        expirationDate = latestExpiry
        isInBillingRetry = billingRetry
        UserDefaults.standard.set(entitled, forKey: Self.cachedIsPlusKey)
    }

    // MARK: - Purchase

    public func purchase(_ product: Product) async -> PurchaseOutcome {
        isPurchasing = true
        defer { isPurchasing = false }

        Analytics.track(.subscriptionStarted, AnalyticsProperties(context: product.id))

        do {
            // Ties the App Store transaction back to this BEFORE account so the
            // backend can reconcile it (spec §37).
            let result = try await product.purchase(
                options: [.appAccountToken(keychain.appAccountToken())]
            )

            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    // A purchase that will not verify does not grant anything.
                    return .failed("That purchase couldn't be verified. Nothing was charged for Plus.")
                }
                await transaction.finish()
                await refreshEntitlements()
                await pushToBackend(transaction)
                return .success

            case .userCancelled:
                return .userCancelled

            case .pending:
                // Ask to Buy. It may complete later through Transaction.updates.
                return .pending

            @unknown default:
                return .failed("Something unexpected happened. Nothing was charged.")
            }
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    // MARK: - Restore

    public func restorePurchases() async -> PurchaseOutcome {
        isRestoring = true
        defer { isRestoring = false }

        Analytics.track(.restoreStarted)

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            Analytics.track(.restoreCompleted, AnalyticsProperties(isPlus: isPlus))

            return isPlus
                ? .success
                : .failed("We couldn't find a subscription on this Apple Account.")
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    // MARK: - Manage

    /// Apple's own management sheet. BEFORE does not build a fake cancellation
    /// flow (spec §39).
    public func showManageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        try? await AppStore.showManageSubscriptions(in: scene)
        await refreshEntitlements()
    }

    // MARK: - Pricing copy

    /// Annual saving, computed from the ACTUAL StoreKit prices — never a
    /// hard-coded "Save 30%" (spec §38).
    public var annualSavingDescription: String? {
        guard let monthly, let yearly else { return nil }
        let yearAtMonthlyRate = monthly.price * 12
        guard yearAtMonthlyRate > yearly.price, yearAtMonthlyRate > 0 else { return nil }

        // `Decimal` has no `rounded()`. Asking for one sends Swift hunting for a
        // floating-point overload of `*`, which is why the compiler reports the
        // mismatch on the multiplication. Keep the arithmetic in `Decimal` and
        // convert only for the rounding.
        let saving = (yearAtMonthlyRate - yearly.price) / yearAtMonthlyRate
        let percentage = Int(NSDecimalNumber(decimal: saving * 100).doubleValue.rounded())
        guard percentage >= 5 else { return nil }
        return "Save \(percentage)%"
    }

    // MARK: - Private

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        await refreshEntitlements()
        await pushToBackend(transaction)
    }

    private func pushToBackend(_ transaction: Transaction) async {
        await syncSubscription(
            SubscriptionSyncPayload(
                productId: transaction.productID,
                originalTransactionId: String(transaction.originalID),
                transactionId: String(transaction.id),
                purchaseDate: transaction.purchaseDate,
                expirationDate: transaction.expirationDate,
                environment: transaction.environment == .production ? "production" : "sandbox",
                appAccountToken: transaction.appAccountToken?.uuidString
            )
        )
    }

    /// Readable messages. Never "Error 2" (spec §45).
    private static func message(for error: Error) -> String {
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .networkError:
                return "We couldn't reach the App Store. Check your connection and try again."
            case .userCancelled:
                return "Cancelled."
            case .notAvailableInStorefront:
                return "BEFORE Plus isn't available in your region yet."
            case .notEntitled:
                return "This Apple Account isn't entitled to that purchase."
            default:
                return "The App Store couldn't complete that. Nothing was charged."
            }
        }
        if let purchaseError = error as? Product.PurchaseError {
            switch purchaseError {
            case .productUnavailable:
                return "That plan isn't available right now."
            case .purchaseNotAllowed:
                return "Purchases are restricted on this device."
            case .ineligibleForOffer:
                return "This Apple Account isn't eligible for that offer."
            default:
                return "The App Store couldn't complete that. Nothing was charged."
            }
        }
        return "Something went wrong with the App Store. Nothing was charged."
    }
}

/// What the backend needs to reconcile a transaction.
public struct SubscriptionSyncPayload: Encodable, Sendable {
    public let productId: String
    public let originalTransactionId: String
    public let transactionId: String
    public let purchaseDate: Date
    public let expirationDate: Date?
    public let environment: String
    public let appAccountToken: String?
}
