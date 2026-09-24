import SwiftData
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — the result screen.
//
// The most important screen in the app. It has to be readable in ten seconds
// (spec §94) and it has to be honest: what BEFORE knows, what it estimated,
// and what it could not judge at all.
// =============================================================================

struct ResultView: View {
    let analysis: Analysis
    var isRevisit: Bool = false
    var onDone: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext

    @State private var showingShare = false
    @State private var showingOutcome = false
    @State private var showingWardrobePrompt = false
    @State private var savedBucket: SavedBucket?
    @State private var recordedOutcome: OutcomeAction?
    @State private var reminderScheduled = false
    @State private var explanation: String?
    @State private var explanationError: String?
    @State private var askedAngle: ExplanationAngle?
    @State private var isExplaining = false
    @State private var showingPaywall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BeforeTheme.Spacing.section) {
                verdictHeader
                productSummary
                whySection
                if !analysis.reasons.positive.isEmpty { goodSection }
                if !analysis.reasons.negative.isEmpty { concernSection }
                beforeSaysSection
                if !analysis.reasons.uncertainties.isEmpty { uncertaintiesSection }
                deeperSection
                actions
                Color.clear.frame(height: BeforeTheme.Spacing.xxl)
            }
            .padding(.top, BeforeTheme.Spacing.l)
        }
        .beforeScreen()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingShare) {
            ShareResultSheet(analysis: analysis)
        }
        .sheet(isPresented: $showingOutcome) {
            OutcomeSheet(analysis: analysis) { action in
                Task { await record(action) }
            }
        }
        .sheet(isPresented: $showingWardrobePrompt) {
            OwnSomethingSimilarSheet(analysis: analysis)
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(placement: "explain")
        }
        .onAppear {
            Analytics.track(.verdictViewed, analysis: analysis, isPlus: environment.isPlus)
        }
    }

    // MARK: Header

    private var verdictHeader: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.l) {
            Text("BEFORE")
                .font(BeforeTheme.Typeface.caption.weight(.semibold))
                .tracking(3)
                .foregroundStyle(BeforeTheme.secondaryText)

            HStack(alignment: .center, spacing: BeforeTheme.Spacing.xl) {
                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
                    Text(analysis.verdict.label)
                        .font(BeforeTheme.Typeface.verdict)
                        .tracking(BeforeTheme.displayTracking)
                        .foregroundStyle(BeforeTheme.color(for: analysis.verdict))
                        .accessibilityIdentifier("result.verdict")

                    Text(analysis.verdict.headline)
                        .font(BeforeTheme.Typeface.title)
                        .foregroundStyle(BeforeTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                ScoreRing(score: analysis.score, verdict: analysis.verdict, animated: !isRevisit)
                    .accessibilityIdentifier("result.score")
            }

            Text(ResultCopy.basis(for: analysis))
                .font(BeforeTheme.Typeface.callout)
                .foregroundStyle(BeforeTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            // Spec §22: a low-confidence result is never presented as definitive.
            if let note = ResultCopy.confidenceNote(for: analysis.confidenceLabel) {
                Label(note, systemImage: "exclamationmark.circle")
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Product

    private var productSummary: some View {
        BeforeCard {
            HStack(alignment: .top, spacing: BeforeTheme.Spacing.m) {
                ProductThumbnail(
                    urlString: analysis.imageUrl,
                    category: analysis.product.category,
                    size: 72
                )

                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
                    Text(analysis.product.displayName)
                        .font(BeforeTheme.Typeface.headline)
                        .foregroundStyle(BeforeTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    PriceLabel(
                        amount: analysis.product.price,
                        currencyCode: analysis.product.currency
                    )

                    // Facts and estimates are labelled, never blended (spec §25).
                    FlowChips(chips: factChips)
                }
            }
        }
    }

    private var factChips: [(String, FactSource)] {
        var chips: [(String, FactSource)] = []
        let product = analysis.product

        if product.price != nil {
            chips.append((
                product.source(for: "price") == .confirmed
                    ? "Price from the product page"
                    : "Price estimated from image",
                product.source(for: "price")
            ))
        } else {
            chips.append(("Price not identified", .unknown))
        }

        if let brand = product.brand {
            chips.append((brand, product.source(for: "brand")))
        } else {
            chips.append(("Brand not identified", .unknown))
        }

        if let material = product.material {
            chips.append((material, product.source(for: "material")))
        }

        return chips
    }

    // MARK: Why

    private var whySection: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
            SectionHeader("Why")
            BeforeCard {
                VStack(spacing: 0) {
                    ForEach(analysis.orderedFactors) { factor in
                        FactorRow(factor)
                        if factor.id != analysis.orderedFactors.last?.id {
                            Divider().overlay(BeforeTheme.divider)
                        }
                    }
                }
            }

            // Spec §93: with no wardrobe data, say so — do not imply knowledge.
            if analysis.lacksWardrobeContext {
                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xs) {
                    Text(ResultCopy.noWardrobeYet)
                        .font(BeforeTheme.Typeface.callout)
                        .foregroundStyle(BeforeTheme.primaryText)
                    Text(ResultCopy.noWardrobeHint)
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, BeforeTheme.Spacing.xs)
            }
        }
    }

    private var goodSection: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
            SectionHeader("The good")
            VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
                ForEach(analysis.reasons.positive, id: \.self) { reason in
                    ReasonRow(text: reason, systemImage: "plus", tint: BeforeTheme.success)
                }
            }
        }
    }

    private var concernSection: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
            SectionHeader("The concern")
            VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
                ForEach(analysis.reasons.negative, id: \.self) { reason in
                    ReasonRow(text: reason, systemImage: "minus", tint: BeforeTheme.warning)
                }
            }
        }
    }

    private var beforeSaysSection: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
            SectionHeader("BEFORE says")
            BeforeCard {
                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
                    // The model's sentence when there is one, the deterministic
                    // fallback when there is not — the user always gets a next step.
                    Text(analysis.reasons.advice.isEmpty
                         ? ResultCopy.nextStep(for: analysis.suggestedAction)
                         : analysis.reasons.advice)
                        .font(BeforeTheme.Typeface.body)
                        .foregroundStyle(BeforeTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if let risk = analysis.reasons.keyRisk {
                        Text(risk)
                            .font(BeforeTheme.Typeface.callout)
                            .foregroundStyle(BeforeTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var uncertaintiesSection: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
            SectionHeader("What BEFORE couldn't confirm")
            VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xs) {
                ForEach(analysis.reasons.uncertainties, id: \.self) { item in
                    Text("· \(item)")
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Going deeper (Plus, spec §35)

    @ViewBuilder
    private var deeperSection: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
            SectionHeader("Go deeper", accessory: environment.isPlus ? nil : "Plus")

            if let explanation {
                BeforeCard {
                    Text(explanation)
                        .font(BeforeTheme.Typeface.body)
                        .foregroundStyle(BeforeTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let explanationError {
                Text(explanationError)
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Three fixed questions, not a text field. BEFORE is not a chatbot
            // (Rule 1), and a free-text box here is how it would become one.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: BeforeTheme.Spacing.s)],
                spacing: BeforeTheme.Spacing.s
            ) {
                ForEach(ExplanationAngle.allCases) { angle in
                    SelectableChip(
                        title: angle.title,
                        isSelected: askedAngle == angle,
                        isDisabled: isExplaining
                    ) {
                        if environment.isPlus {
                            Task { await explain(angle) }
                        } else {
                            Analytics.track(.paywallViewed, AnalyticsProperties(context: "explain"))
                            showingPaywall = true
                        }
                    }
                }
            }

            if isExplaining {
                HStack(spacing: BeforeTheme.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Thinking about it…")
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.secondaryText)
                }
            }
        }
    }

    private func explain(_ angle: ExplanationAngle) async {
        guard !isExplaining else { return }
        isExplaining = true
        askedAngle = angle
        explanationError = nil
        defer { isExplaining = false }

        do {
            explanation = try await environment.analyses.explain(
                analysisId: analysis.analysisId,
                angle: angle
            )
        } catch {
            explanation = nil
            explanationError = (error as? APIError)?.userMessage
                ?? "We couldn't get a deeper explanation just now."
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: BeforeTheme.Spacing.m) {
            if let savedBucket {
                Label("Saved to \(savedBucket.title)", systemImage: "checkmark")
                    .font(BeforeTheme.Typeface.callout)
                    .foregroundStyle(BeforeTheme.success)
                    .frame(maxWidth: .infinity)
            } else {
                BeforeButton("Save to My Maybe", systemImage: "bookmark") {
                    save(to: .maybe)
                }
                .accessibilityIdentifier("result.save")
            }

            BeforeSecondaryButton("Share", systemImage: "square.and.arrow.up") {
                Analytics.track(.shareStarted, analysis: analysis, isPlus: environment.isPlus)
                showingShare = true
            }

            // The only notification BEFORE offers unprompted, and only on the
            // verdict where it is genuinely useful: BEFORE has just said to
            // sleep on it (spec §64).
            if analysis.verdict == .wait, environment.notifications.permission != .denied {
                if reminderScheduled {
                    Label("We'll remind you in 48 hours", systemImage: "bell")
                        .font(BeforeTheme.Typeface.callout)
                        .foregroundStyle(BeforeTheme.success)
                } else {
                    BeforeSecondaryButton("Remind me in 48 hours", systemImage: "bell") {
                        Task { await scheduleReminder() }
                    }
                    .accessibilityIdentifier("result.remindMe")
                }
            }

            if recordedOutcome == nil {
                BeforeTextButton("What did you do?") { showingOutcome = true }
            } else if let recordedOutcome {
                Text("You marked this \(recordedOutcome.title.lowercased()).")
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.tertiaryText)
            }

            // Future-ready, and honest about it (spec §23). Not a dead button
            // pretending to be a feature.
            Button {} label: {
                Text("Ask the Girls")
                    .font(BeforeTheme.Typeface.callout)
                    .foregroundStyle(BeforeTheme.tertiaryText)
            }
            .disabled(true)
            .accessibilityHint("Coming soon")
        }
    }

    // MARK: Behaviour

    private func save(to bucket: SavedBucket) {
        savedBucket = bucket

        let cached = CachedAnalysis.from(analysis, bucket: bucket)
        modelContext.insert(cached)
        try? modelContext.save()

        Analytics.track(.itemSaved, analysis: analysis, isPlus: environment.isPlus)

        // Ask about the wardrobe right after a save, which is the moment the
        // user is most willing to answer (spec §26).
        if analysis.lacksWardrobeContext || analysis.verdict != .buy {
            showingWardrobePrompt = true
        }
    }

    /// Asks for notification permission at the one moment it makes sense: the
    /// user has just asked to be reminded about a specific thing.
    private func scheduleReminder() async {
        let notifications = environment.notifications

        if notifications.permission == .notDetermined {
            guard await notifications.requestPermission() else { return }
        }

        reminderScheduled = await notifications.scheduleWaitReminder(for: analysis)
    }

    private func record(_ action: OutcomeAction) async {
        recordedOutcome = action

        // Being reminded to decide something already decided is the fastest way
        // to get notifications turned off.
        environment.notifications.cancelReminders(for: analysis.analysisId)

        // Outcomes are the only ground truth BEFORE gets, so this is the one
        // follow-up worth scheduling — and only if they already opted in.
        if action == .bought {
            await environment.notifications.schedulePurchaseFollowUp(for: analysis)
        }

        try? await environment.analyses.recordOutcome(
            analysisId: analysis.analysisId,
            outcome: OutcomeDraft(
                action: action,
                actualPrice: action == .bought ? analysis.product.price : nil,
                currency: analysis.product.currency
            )
        )

        // Mirror locally so "potential spend avoided" works offline.
        let descriptor = FetchDescriptor<CachedAnalysis>(
            predicate: #Predicate { $0.analysisId == analysis.analysisId }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.outcomeActionRaw = action.rawValue
            if action == .bought { existing.savedBucketRaw = SavedBucket.bought.rawValue }
            try? modelContext.save()
        }

        switch action {
        case .bought: Analytics.track(.itemBought, analysis: analysis, isPlus: environment.isPlus)
        case .skipped: Analytics.track(.itemSkipped, analysis: analysis, isPlus: environment.isPlus)
        case .stillThinking: break
        }
    }
}

// MARK: - Pieces

struct ReasonRow: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: BeforeTheme.Spacing.s) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .padding(.top, 3)
            Text(text)
                .font(BeforeTheme.Typeface.body)
                .foregroundStyle(BeforeTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Wrapping chips that behave at accessibility text sizes.
struct FlowChips: View {
    let chips: [(String, FactSource)]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: BeforeTheme.Spacing.xs, alignment: .leading)],
            alignment: .leading,
            spacing: BeforeTheme.Spacing.xs
        ) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                SourceChip(chip.0, source: chip.1)
            }
        }
    }
}

#Preview("Result — WAIT") {
    NavigationStack { ResultView(analysis: Fixtures.leatherJacket) }
        .environment(AppEnvironment.preview)
        .modelContainer(LocalStore.makeContainer(inMemory: true))
}

#Preview("Result — no wardrobe") {
    NavigationStack { ResultView(analysis: Fixtures.firstTimeNoWardrobe) }
        .environment(AppEnvironment.preview)
        .modelContainer(LocalStore.makeContainer(inMemory: true))
}
