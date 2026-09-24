import SwiftData
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — Home.
//
// The screen has one job: make the next check obvious. Everything else is
// secondary and stays below the fold (spec §9, §57).
// =============================================================================

struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \CachedAnalysis.createdAt, order: .reverse)
    private var cached: [CachedAnalysis]

    @State private var checkSheet: CheckEntryPoint?
    @State private var activeDraft: AnalysisRequestDraft?
    @State private var showingPaywall = false

    private var recent: [CachedAnalysis] { Array(cached.prefix(5)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.section) {
                    hero
                    // Above the recent list on purpose: an unfinished check is
                    // the most actionable thing on this screen.
                    PendingUploadsCard { draft in activeDraft = draft }
                    quickActions
                    if !recent.isEmpty { recentlyConsidered }
                    insight
                    Color.clear.frame(height: BeforeTheme.Spacing.xxl)
                }
                .padding(.top, BeforeTheme.Spacing.l)
            }
            .beforeScreen()
            .navigationTitle("")
            .toolbar { ToolbarItem(placement: .topBarLeading) { wordmark } }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { usageBadge } }
            .refreshable { await environment.refreshUsage() }
        }
        .sheet(item: $checkSheet) { entry in
            CheckSomethingSheet(entryPoint: entry) { draft in
                checkSheet = nil
                activeDraft = draft
            }
        }
        .fullScreenCover(item: $activeDraft) { draft in
            AnalysisFlowView(draft: draft)
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(placement: "home_quota")
        }
        // A shared item opens the check sheet already filled in (spec §13).
        .onChange(of: environment.pendingSharedPayload?.id) { _, _ in
            guard let payload = environment.pendingSharedPayload else { return }
            checkSheet = .shared(payload)
        }
        .task { await environment.refreshUsage() }
    }

    // MARK: Pieces

    private var wordmark: some View {
        Text("BEFORE")
            .font(BeforeTheme.Typeface.caption.weight(.semibold))
            .tracking(3)
            .foregroundStyle(BeforeTheme.primaryText)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var usageBadge: some View {
        if environment.isPlus {
            PremiumBadge()
        } else if let description = environment.usage?.remainingDescription {
            Button { showingPaywall = true } label: {
                Text(description)
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.secondaryText)
            }
            .accessibilityHint("Opens BEFORE Plus")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.m) {
            Text("Before you buy it,\nask BEFORE.")
                .font(BeforeTheme.Typeface.hero)
                .tracking(BeforeTheme.displayTracking)
                .foregroundStyle(BeforeTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your personal second opinion for the things you're thinking about.")
                .font(BeforeTheme.Typeface.callout)
                .foregroundStyle(BeforeTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            BeforeButton("Check something", systemImage: "plus") {
                if environment.usage?.hasChecksLeft == false {
                    Analytics.track(.paywallViewed, AnalyticsProperties(context: "home_quota"))
                    showingPaywall = true
                } else {
                    checkSheet = .menu
                }
            }
            .padding(.top, BeforeTheme.Spacing.s)
            .accessibilityIdentifier("home.checkSomething")
        }
    }

    private var quickActions: some View {
        HStack(spacing: BeforeTheme.Spacing.s) {
            QuickAction(title: "Paste a link", systemImage: "link") { checkSheet = .url }
            QuickAction(title: "Pick a photo", systemImage: "photo") { checkSheet = .photos }
            QuickAction(title: "Take a photo", systemImage: "camera") { checkSheet = .camera }
        }
    }

    private var recentlyConsidered: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
            SectionHeader("Recently considered")

            VStack(spacing: 0) {
                ForEach(recent) { item in
                    NavigationLink {
                        if let analysis = item.analysis {
                            ResultView(analysis: analysis, isRevisit: true)
                        } else {
                            // Cached row without a decodable payload — rare,
                            // but it must not be a dead tap.
                            ErrorState(
                                message: "This one couldn't be reopened offline.",
                                retry: nil
                            )
                        }
                    } label: {
                        if let analysis = item.analysis {
                            AnalysisRow(analysis)
                        } else {
                            CachedRowFallback(item: item)
                        }
                    }
                    .buttonStyle(.plain)

                    if item.id != recent.last?.id {
                        Divider().overlay(BeforeTheme.divider)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var insight: some View {
        let avoided = potentialSpendAvoided()
        if avoided.amount > 0, let formatted = Formatting.price(
            avoided.amount,
            currencyCode: avoided.currency
        ) {
            BeforeCard {
                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xs) {
                    Text("Potential spend avoided")
                        .font(BeforeTheme.Typeface.sectionHeader)
                        .tracking(0.8)
                        .foregroundStyle(BeforeTheme.secondaryText)
                    Text(formatted)
                        .font(BeforeTheme.Typeface.title)
                        .monospacedDigit()
                        .foregroundStyle(BeforeTheme.primaryText)
                    // Never "you saved" — BEFORE cannot know they would have
                    // bought it (spec §32).
                    Text("Things BEFORE suggested skipping, that you skipped, this month.")
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if cached.count < 3 {
            BeforeCard {
                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xs) {
                    Text("Your shopping memory is getting smarter.")
                        .font(BeforeTheme.Typeface.headline)
                        .foregroundStyle(BeforeTheme.primaryText)
                    Text("Keep checking things and BEFORE learns what you actually wear.")
                        .font(BeforeTheme.Typeface.callout)
                        .foregroundStyle(BeforeTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Counted locally from what this device knows: BYE verdicts the user then
    /// marked skipped, in the current month, with a known price.
    private func potentialSpendAvoided() -> (amount: Double, currency: String?) {
        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: .now)

        let qualifying = cached.filter { item in
            item.verdict == .bye
                && item.outcomeActionRaw == OutcomeAction.skipped.rawValue
                && item.price != nil
                && (month.map { $0.contains(item.createdAt) } ?? true)
        }

        // Mixing currencies into one total would be a lie, so only the user's
        // own currency is counted.
        let currency = environment.profile?.currency
        let total = qualifying
            .filter { currency == nil || $0.currency == currency }
            .reduce(0.0) { $0 + ($1.price ?? 0) }

        return (total, currency)
    }
}

// MARK: - Pieces

struct QuickAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: BeforeTheme.Spacing.s) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(BeforeTheme.accent)
                Text(title)
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.primaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 84)
            .background(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.card, style: .continuous)
                    .fill(BeforeTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.card, style: .continuous)
                    .stroke(BeforeTheme.divider, lineWidth: BeforeTheme.Sizing.hairline)
            )
        }
        .buttonStyle(.plain)
    }
}

struct CachedRowFallback: View {
    let item: CachedAnalysis

    var body: some View {
        HStack(spacing: BeforeTheme.Spacing.m) {
            ProductThumbnail(urlString: item.imageURLString, category: item.category)
            VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xs) {
                Text(item.productName ?? "Not confidently identified")
                    .font(BeforeTheme.Typeface.body)
                    .foregroundStyle(BeforeTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: BeforeTheme.Spacing.s) {
                    VerdictBadge(item.verdict)
                    Text("\(item.score)")
                        .font(BeforeTheme.Typeface.number)
                        .foregroundStyle(BeforeTheme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Text(Formatting.relativeDay(item.createdAt))
                .font(BeforeTheme.Typeface.caption)
                .foregroundStyle(BeforeTheme.tertiaryText)
        }
        .padding(.vertical, BeforeTheme.Spacing.s)
    }
}

#Preview("Home") {
    HomeView()
        .environment(AppEnvironment.preview)
        .modelContainer(LocalStore.makeContainer(inMemory: true))
}
