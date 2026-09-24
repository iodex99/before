import StoreKit
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — the paywall (spec §38).
//
// Every price string comes from StoreKit, so it is localised and correct in
// every storefront. Nothing here is hard-coded — including the annual saving,
// which is computed from the two real prices or not shown at all.
//
// No countdown, no fake scarcity, no dark pattern. The close button is where
// you expect it.
// =============================================================================

struct PaywallView: View {
    /// Where this was opened from. Analytics only.
    var placement: String = "unknown"

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var selection: Plan = .yearly
    @State private var message: String?
    @State private var didSucceed = false

    enum Plan: Hashable { case monthly, yearly }

    private var subscriptions: SubscriptionManager { environment.subscriptions }

    private var selectedProduct: Product? {
        switch selection {
        case .monthly: subscriptions.monthly
        case .yearly: subscriptions.yearly
        }
    }

    private let benefits = [
        ("infinity", "Unlimited checks"),
        ("tshirt", "Remember what you own"),
        ("checkmark.circle", "Track what you actually bought"),
        ("chart.line.uptrend.xyaxis", "Learn your shopping patterns"),
        ("sparkles", "Better recommendations over time"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.section) {
                    header
                    benefitList
                    plans
                    purchaseControls
                    legal
                }
                .padding(.top, BeforeTheme.Spacing.l)
                .padding(.bottom, BeforeTheme.Spacing.xxl)
            }
            .beforeScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("paywall.close")
                }
            }
        }
        .task {
            Analytics.track(.paywallViewed, AnalyticsProperties(context: placement))
            if subscriptions.loadState != .loaded { await subscriptions.loadProducts() }
        }
        .onChange(of: subscriptions.isPlus) { _, isPlus in
            if isPlus && didSucceed { dismiss() }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
            HStack {
                Text("BEFORE")
                    .font(BeforeTheme.Typeface.caption.weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(BeforeTheme.secondaryText)
                PremiumBadge()
            }

            Text("Know before you buy.")
                .font(BeforeTheme.Typeface.hero)
                .tracking(BeforeTheme.displayTracking)
                .foregroundStyle(BeforeTheme.primaryText)

            Text("BEFORE gets smarter the more you use it.")
                .font(BeforeTheme.Typeface.callout)
                .foregroundStyle(BeforeTheme.secondaryText)
        }
    }

    private var benefitList: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.m) {
            ForEach(benefits, id: \.1) { icon, title in
                HStack(spacing: BeforeTheme.Spacing.m) {
                    Image(systemName: icon)
                        .foregroundStyle(BeforeTheme.accent)
                        .frame(width: 24)
                    Text(title)
                        .font(BeforeTheme.Typeface.body)
                        .foregroundStyle(BeforeTheme.primaryText)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var plans: some View {
        switch subscriptions.loadState {
        case .loading, .idle:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, BeforeTheme.Spacing.xl)

        case .failed(let reason):
            ErrorState(
                title: "We couldn't load plans.",
                message: reason,
                retry: { Task { await subscriptions.loadProducts() } }
            )

        case .loaded:
            VStack(spacing: BeforeTheme.Spacing.m) {
                if let yearly = subscriptions.yearly {
                    PlanRow(
                        product: yearly,
                        caption: "per year",
                        badge: subscriptions.annualSavingDescription,
                        isSelected: selection == .yearly
                    ) { selection = .yearly }
                }
                if let monthly = subscriptions.monthly {
                    PlanRow(
                        product: monthly,
                        caption: "per month",
                        badge: nil,
                        isSelected: selection == .monthly
                    ) { selection = .monthly }
                }
            }
        }
    }

    private var purchaseControls: some View {
        VStack(spacing: BeforeTheme.Spacing.m) {
            BeforeButton(
                "Start BEFORE Plus",
                isLoading: subscriptions.isPurchasing
            ) {
                Task { await purchase() }
            }
            .disabled(selectedProduct == nil)
            .accessibilityIdentifier("paywall.subscribe")

            BeforeTextButton(subscriptions.isRestoring ? "Restoring…" : "Restore Purchases") {
                Task { await restore() }
            }
            .disabled(subscriptions.isRestoring)
            .accessibilityIdentifier("paywall.restore")

            if let message {
                Text(message)
                    .font(BeforeTheme.Typeface.callout)
                    .foregroundStyle(didSucceed ? BeforeTheme.success : BeforeTheme.destructive)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Apple requires that auto-renewal is stated plainly. It also
            // happens to be the honest thing to say.
            Text("Renews automatically until cancelled. Manage or cancel any time in Settings.")
                .font(BeforeTheme.Typeface.caption)
                .foregroundStyle(BeforeTheme.tertiaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var legal: some View {
        HStack(spacing: BeforeTheme.Spacing.l) {
            if let terms = AppConfig.termsURL {
                Button("Terms") { openURL(terms) }
            }
            if let privacy = AppConfig.privacyURL {
                Button("Privacy") { openURL(privacy) }
            }
            Button("Manage Subscription") {
                Task { await subscriptions.showManageSubscriptions() }
            }
        }
        .font(BeforeTheme.Typeface.caption)
        .foregroundStyle(BeforeTheme.secondaryText)
        .frame(maxWidth: .infinity)
    }

    // MARK: Behaviour

    private func purchase() async {
        guard let product = selectedProduct else { return }
        message = nil

        switch await subscriptions.purchase(product) {
        case .success:
            didSucceed = true
            message = "You're on BEFORE Plus."
            await environment.refreshUsage()

        case .userCancelled:
            break  // not an error, and not worth a message

        case .pending:
            message = "That purchase needs approval. We'll unlock Plus as soon as it goes through."

        case .failed(let reason):
            message = reason
        }
    }

    private func restore() async {
        message = nil
        switch await subscriptions.restorePurchases() {
        case .success:
            didSucceed = true
            message = "Your subscription is restored."
            await environment.refreshUsage()
        case .failed(let reason):
            message = reason
        case .userCancelled, .pending:
            break
        }
    }
}

// MARK: - Plan row

struct PlanRow: View {
    let product: Product
    let caption: String
    let badge: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BeforeTheme.Spacing.m) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? BeforeTheme.accent : BeforeTheme.divider)

                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(BeforeTheme.Typeface.headline)
                        .foregroundStyle(BeforeTheme.primaryText)
                    Text(caption)
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.secondaryText)
                }

                Spacer(minLength: BeforeTheme.Spacing.s)

                VStack(alignment: .trailing, spacing: 2) {
                    // StoreKit's own localised string — correct currency,
                    // correct formatting, in every storefront.
                    Text(product.displayPrice)
                        .font(BeforeTheme.Typeface.headline)
                        .monospacedDigit()
                        .foregroundStyle(BeforeTheme.primaryText)
                    if let badge {
                        Text(badge)
                            .font(BeforeTheme.Typeface.caption.weight(.semibold))
                            .foregroundStyle(BeforeTheme.accent)
                    }
                }
            }
            .padding(BeforeTheme.Spacing.l)
            .frame(minHeight: BeforeTheme.Sizing.minimumTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                    .fill(isSelected ? BeforeTheme.accentSubtle : BeforeTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                    .stroke(isSelected ? BeforeTheme.accent : BeforeTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Paywall") {
    PaywallView().environment(AppEnvironment.preview)
}
