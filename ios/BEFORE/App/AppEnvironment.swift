import Foundation
import Observation
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — composition root.
//
// Everything is wired here, once. Nothing below this file reaches for a
// singleton, which is what makes every screen testable with fixtures.
// =============================================================================

@MainActor
@Observable
public final class AppEnvironment {

    // MARK: Services

    public let auth: AuthService
    public let subscriptions: SubscriptionManager
    public let analyses: AnalysisRepositoryProtocol
    public let profiles: ProfileRepositoryProtocol
    public let wardrobe: WardrobeRepositoryProtocol
    public let sharedInbox: SharedInbox
    public let notifications: NotificationService
    public let keychain: KeychainStore

    // MARK: Shared state

    public private(set) var profile: UserProfile?
    public private(set) var usage: UsageSnapshot?
    /// A payload handed over by the share extension, waiting to be analysed.
    public var pendingSharedPayload: SharedPayload?

    public var isPlus: Bool { subscriptions.isPlus }

    /// Onboarding is a local flag: it is about this device's first run, not
    /// about account state, and it must work before the first network call.
    public var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.onboardingKey) }
    }

    private static let onboardingKey = "before.onboarding.completed"

    // MARK: Init

    public init(
        auth: AuthService,
        subscriptions: SubscriptionManager,
        analyses: AnalysisRepositoryProtocol,
        profiles: ProfileRepositoryProtocol,
        wardrobe: WardrobeRepositoryProtocol,
sharedInbox: SharedInbox,
        notifications: NotificationService,
        keychain: KeychainStore
    ) {
        self.auth = auth
        self.subscriptions = subscriptions
        self.analyses = analyses
        self.profiles = profiles
        self.wardrobe = wardrobe
        self.sharedInbox = sharedInbox
        self.notifications = notifications
        self.keychain = keychain
    }

    /// The real wiring used by the app.
    public static func live() -> AppEnvironment {
        let keychain = KeychainStore()
        let auth = AuthService(keychain: keychain)

        let tokenProvider = KeychainTokenProvider(keychain: keychain) { [weak auth] in
            await auth?.restore()
        }

        let client = APIClient(
            baseURL: AppConfig.apiBaseURL,
            anonKey: AppConfig.supabaseAnonKey,
            tokenProvider: tokenProvider
        )

        // The subscription manager pushes verified transactions to the backend
        // through the same client, so there is one HTTP path in the app.
        let subscriptions = SubscriptionManager(keychain: keychain) { payload in
            guard let request = try? APIRequest.post("subscription-sync", body: payload) else { return }
            try? await client.send(request)
        }

        return AppEnvironment(
            auth: auth,
            subscriptions: subscriptions,
            analyses: AnalysisRepository(client: client),
            profiles: ProfileRepository(client: client),
            wardrobe: WardrobeRepository(client: client),
            sharedInbox: SharedInbox(appGroupIdentifier: AppConfig.appGroupIdentifier),
            notifications: NotificationService(),
            keychain: keychain
        )
    }

    // MARK: Lifecycle

    /// Launch work. Deliberately does nothing blocking: the UI is on screen
    /// before any of this runs (spec §83).
    public func bootstrap() async {
        await auth.restore()
        subscriptions.start()

        guard auth.state.isSignedIn else { return }

        // Independent calls, so they run together rather than in sequence.
        async let profileTask: Void = refreshProfile()
        async let usageTask: Void = refreshUsage()
        _ = await (profileTask, usageTask)

        // Reads the current authorisation. Does NOT prompt — permission is only
        // ever requested from a button the user pressed for a stated reason.
        await notifications.refreshPermission()

        // Sweep anything an interrupted share left behind (spec §13).
        sharedInbox.purgeStale()
        drainSharedInbox()
    }

    public func refreshProfile() async {
        guard auth.state.isSignedIn else { return }
        profile = try? await profiles.me()
    }

    public func refreshUsage() async {
        guard auth.state.isSignedIn else { return }
        usage = try? await analyses.usage()
    }

    /// Send the device's locale, currency, and timezone once, so prices and
    /// dates are right without asking the user anything (spec §3).
    public func syncDeviceSettings() async {
        guard auth.state.isSignedIn else { return }
        profile = try? await profiles.updatePreferences(.fromDeviceSettings())
    }

    /// Pick up the next thing the share extension left for us.
    public func drainSharedInbox() {
        guard pendingSharedPayload == nil else { return }
        guard let next = sharedInbox.pendingPayloads().first else { return }
        pendingSharedPayload = next
        Analytics.track(.shareImported, AnalyticsProperties(context: next.kind.rawValue))
    }

    /// Called after a shared payload has been turned into an analysis draft.
    public func consumeSharedPayload(_ payload: SharedPayload) {
        sharedInbox.consume(payload)
        if pendingSharedPayload?.id == payload.id { pendingSharedPayload = nil }
        drainSharedInbox()
    }

    public func signOut() {
        auth.signOut()
        profile = nil
        usage = nil
    }
}

// MARK: - Injection
//
// Injected with the Observation-native `.environment(_:)` and read with
// `@Environment(AppEnvironment.self)`.
//
// Deliberately NOT an EnvironmentKey: that protocol's `defaultValue` is
// non-isolated, so supplying a `@MainActor` default is a conformance error under
// strict concurrency. Requiring explicit injection is also better — a screen
// rendered without an environment should fail loudly in a preview rather than
// quietly attach itself to a throwaway default.
