import SwiftData
import SwiftUI
import UIKit
import BeforeKit

// =============================================================================
// BEFORE — Profile, settings, and privacy (spec §31, §43, §77).
//
// The shopping profile only appears once there is enough data to say something
// true. Below ten analyses it says so plainly rather than inventing a pattern
// from three data points (spec §31, §91).
// =============================================================================

struct ProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @Query private var cached: [CachedAnalysis]

    @State private var showingPaywall = false
    @State private var showingDeleteConfirmation = false
    @State private var showingFinalDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var isExporting = false
    @State private var exportedData: ExportDocument?
    @State private var errorMessage: String?

    private static let insightsThreshold = 10

    var body: some View {
        NavigationStack {
            List {
                profileSection
                subscriptionSection
                shoppingProfileSection
                notificationsSection
                privacySection
                aboutSection
                accountSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(BeforeTheme.background.ignoresSafeArea())
            .navigationTitle("Profile")
            .sheet(isPresented: $showingPaywall) { PaywallView(placement: "profile") }
            .sheet(item: $exportedData) { ExportShareSheet(document: $0) }
            .task { await environment.refreshProfile() }
        }
    }

    // MARK: Sections

    private var profileSection: some View {
        Section {
            HStack(spacing: BeforeTheme.Spacing.m) {
                Circle()
                    .fill(BeforeTheme.accentSubtle)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Text(initials)
                            .font(BeforeTheme.Typeface.headline)
                            .foregroundStyle(BeforeTheme.accent)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(environment.profile?.greetingName ?? "Your BEFORE profile")
                        .font(BeforeTheme.Typeface.headline)
                        .foregroundStyle(BeforeTheme.primaryText)
                    Text("\(cached.count) \(cached.count == 1 ? "item" : "items") checked")
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.secondaryText)
                }

                Spacer()
                if environment.isPlus { PremiumBadge() }
            }
            .padding(.vertical, BeforeTheme.Spacing.xs)
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        Section("Subscription") {
            if environment.isPlus {
                LabeledContent("Plan", value: "BEFORE Plus")
                if let expiry = environment.subscriptions.expirationDate {
                    LabeledContent("Renews", value: Formatting.relativeDay(expiry))
                }
                if environment.subscriptions.isInBillingRetry {
                    Text("There's a problem with your payment method. Apple is retrying.")
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.warning)
                }
                Button("Manage Subscription") {
                    Task { await environment.subscriptions.showManageSubscriptions() }
                }
            } else {
                if let usage = environment.usage, let description = usage.remainingDescription {
                    LabeledContent("This month", value: description)
                }
                Button("See BEFORE Plus") { showingPaywall = true }
                Button("Restore Purchases") {
                    Task { _ = await environment.subscriptions.restorePurchases() }
                }
            }
        }
    }

    @ViewBuilder
    private var shoppingProfileSection: some View {
        Section("Your BEFORE profile") {
            if let preferences = environment.profile?.preferences {
                if !preferences.favoriteStyles.isEmpty {
                    LabeledContent(
                        "Style",
                        value: preferences.favoriteStyles.map(\.title).joined(separator: ", ")
                    )
                }
                if !preferences.shoppingPriorities.isEmpty {
                    LabeledContent(
                        "Priorities",
                        value: preferences.shoppingPriorities.map(\.title).joined(separator: ", ")
                    )
                }
            }

            LabeledContent("Checked", value: "\(cached.count)")
            LabeledContent("Bought", value: "\(count(of: .bought))")
            LabeledContent("Skipped", value: "\(count(of: .skipped))")

            if cached.count < Self.insightsThreshold {
                // Spec §31: do not manufacture statistics from thin data.
                Text("Keep checking things to unlock your shopping profile.")
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.tertiaryText)
            } else if let insight = derivedInsight {
                Text(insight)
                    .font(BeforeTheme.Typeface.callout)
                    .foregroundStyle(BeforeTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Spec §64: no permission prompt anywhere except a button the user pressed
    /// for a stated reason. This section reports state and points at Settings;
    /// it never asks.
    @ViewBuilder
    private var notificationsSection: some View {
        Section("Reminders") {
            switch environment.notifications.permission {
            case .authorised:
                LabeledContent("Notifications", value: "On")
                Text("BEFORE only sends what you ask for: a 48-hour reminder on something you're weighing up, and one follow-up after a purchase.")
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Cancel all reminders") { environment.notifications.cancelAll() }

            case .denied:
                LabeledContent("Notifications", value: "Off")
                Button("Open Settings") { openSettings() }

            case .notDetermined:
                Text("BEFORE will ask the first time you tap \"Remind me in 48 hours\" on a result.")
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Button(isExporting ? "Preparing your data…" : "Export my data") {
                Task { await exportData() }
            }
            .disabled(isExporting)
            Button("Delete my saved content", role: .destructive) { deleteLocalContent() }

            if let privacy = AppConfig.privacyURL {
                Button("Privacy Policy") { openURL(privacy) }
            }
            if let terms = AppConfig.termsURL {
                Button("Terms of Use") { openURL(terms) }
            }
        } footer: {
            Text("BEFORE never sells your wardrobe or purchase history, and your photos are stored privately.")
                .font(BeforeTheme.Typeface.caption)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: versionString)
            // App Store review guideline: the AI nature of the advice is stated
            // plainly, in the app, not buried in a policy (spec §80).
            Text("Verdicts are generated by AI from the information you provide. BEFORE can be wrong, and it will sometimes tell you not to buy something.")
                .font(BeforeTheme.Typeface.caption)
                .foregroundStyle(BeforeTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let email = AppConfig.supportEmail,
               let url = URL(string: "mailto:\(email)") {
                Button("Contact support") { openURL(url) }
            }
        }
    }

    private var accountSection: some View {
        Section {
            Button("Sign out") { environment.signOut() }

            Button("Delete account", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .accessibilityIdentifier("profile.deleteAccount")

            if let errorMessage {
                Text(errorMessage)
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.destructive)
            }
        }
        // Two steps, on purpose. This is irreversible.
        .confirmationDialog(
            "Delete your BEFORE account?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) { showingFinalDeleteConfirmation = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your BEFORE account and associated data: your analyses, saved items, wardrobe, and photos.")
        }
        .alert("This cannot be undone", isPresented: $showingFinalDeleteConfirmation) {
            Button("Delete everything", role: .destructive) { Task { await deleteAccount() } }
            Button("Keep my account", role: .cancel) {}
        } message: {
            // We cannot cancel an App Store subscription and must not imply we
            // can (spec §77).
            Text("Your data will be deleted immediately. If you have a BEFORE Plus subscription, cancel it separately in Settings — only Apple can do that.")
        }
    }

    // MARK: Derived

    private var initials: String {
        guard let name = environment.profile?.greetingName, let first = name.first else { return "B" }
        return String(first).uppercased()
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func count(of action: OutcomeAction) -> Int {
        cached.filter { $0.outcomeActionRaw == action.rawValue }.count
    }

    /// One observation, only when the data supports it.
    private var derivedInsight: String? {
        let withOutcome = cached.filter { $0.outcomeActionRaw != nil }
        guard withOutcome.count >= Self.insightsThreshold else { return nil }

        let skipped = withOutcome.filter { $0.outcomeActionRaw == OutcomeAction.skipped.rawValue }
        let ratio = Double(skipped.count) / Double(withOutcome.count)

        if ratio >= 0.5 {
            return "You skip more than half of what you check. BEFORE is mostly confirming instincts you already have."
        }

        let prices = cached.compactMap(\.price).filter { $0 > 0 }
        guard prices.count >= Self.insightsThreshold else { return nil }
        let average = prices.reduce(0, +) / Double(prices.count)
        guard let formatted = Formatting.price(average, currencyCode: environment.profile?.currency) else {
            return nil
        }
        return "Your average checked item is \(formatted)."
    }

    // MARK: Actions

    /// The complete server-side export (spec §43): profile, preferences, every
    /// analysis, wardrobe, saved items, outcomes, usage and subscriptions, plus
    /// short-lived links to the images.
    ///
    /// Falls back to the on-device mirror when offline, because an export that
    /// only works with a connection is not much of a guarantee.
    private func exportData() async {
        isExporting = true
        defer { isExporting = false }
        errorMessage = nil

        do {
            exportedData = ExportDocument(data: try await environment.profiles.exportData())
        } catch {
            let local = cached.compactMap(\.analysis)
            guard let data = try? JSON.encoder.encode(local) else {
                errorMessage = (error as? APIError)?.userMessage ?? "We couldn't prepare your export."
                return
            }
            exportedData = ExportDocument(data: data, isPartial: true)
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func deleteLocalContent() {
        for item in cached { modelContext.delete(item) }
        try? modelContext.save()
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await environment.profiles.deleteAccount()
            deleteLocalContent()
            environment.keychain.removeAll()
            environment.signOut()
            Analytics.track(.accountDeleted)
        } catch {
            errorMessage = (error as? APIError)?.userMessage
                ?? "We couldn't delete your account. Please try again."
        }
    }
}

/// Wrapper so an export can be handed to a share sheet.
struct ExportDocument: Identifiable {
    let id = UUID()
    let data: Data
    /// True when the server could not be reached and this is the local mirror.
    var isPartial = false
}

/// Writes the export to a temporary file and hands it to the system share
/// sheet. A file rather than a string: an export is a document someone keeps.
struct ExportShareSheet: View {
    let document: ExportDocument
    @Environment(.dismiss) private var dismiss

    private var fileURL: URL? {
        let name = "before-export-(ISO8601DateFormatter().string(from: .now).prefix(10)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try document.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: BeforeTheme.Spacing.l) {
                if document.isPartial {
                    Text("We couldn't reach the server, so this is the copy stored on this device. Try again on a connection for the complete export.")
                        .font(BeforeTheme.Typeface.callout)
                        .foregroundStyle(BeforeTheme.warning)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Everything BEFORE holds about your account. Image links expire one hour after this file was created.")
                    .font(BeforeTheme.Typeface.callout)
                    .foregroundStyle(BeforeTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let fileURL {
                    ShareLink(item: fileURL) {
                        Text("Save or send")
                            .font(BeforeTheme.Typeface.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: BeforeTheme.Sizing.buttonHeight)
                            .foregroundStyle(BeforeTheme.background)
                            .background(
                                RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                                    .fill(BeforeTheme.primaryText)
                            )
                    }
                } else {
                    Text("We couldn't prepare the file.")
                        .font(BeforeTheme.Typeface.callout)
                        .foregroundStyle(BeforeTheme.destructive)
                }

                Spacer()
            }
            .padding(.top, BeforeTheme.Spacing.xl)
            .beforeScreen()
            .navigationTitle("Your data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview("Profile") {
    ProfileView()
        .environment(AppEnvironment.preview)
        .modelContainer(LocalStore.makeContainer(inMemory: true))
}
