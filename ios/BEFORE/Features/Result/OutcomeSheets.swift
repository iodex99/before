import SwiftData
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — what happened next.
//
// Outcomes are the only ground truth this product ever gets (spec §29, §30).
// Both sheets are short, skippable, and asked once. "Do not bombard the user"
// is a requirement, not a nicety — a shopping app that nags gets deleted.
// =============================================================================

struct OutcomeSheet: View {
    let analysis: Analysis
    let onSelect: (OutcomeAction) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xl) {
                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
                    Text("What did you do?")
                        .font(BeforeTheme.Typeface.hero)
                        .tracking(BeforeTheme.displayTracking)
                        .foregroundStyle(BeforeTheme.primaryText)
                    Text("This is how BEFORE gets better at knowing what you actually wear.")
                        .font(BeforeTheme.Typeface.callout)
                        .foregroundStyle(BeforeTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, BeforeTheme.Spacing.l)

                VStack(spacing: BeforeTheme.Spacing.m) {
                    ForEach(OutcomeAction.allCases, id: \.rawValue) { action in
                        SelectableRow(title: action.title, isSelected: false) {
                            onSelect(action)
                            dismiss()
                        }
                        .accessibilityIdentifier("outcome.\(action.rawValue)")
                    }
                }

                Spacer()
            }
            .beforeScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Asked after an analysis, not during onboarding. Spec §26: the wardrobe is
/// built up naturally, one answer at a time.
struct OwnSomethingSimilarSheet: View {
    let analysis: Analysis

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var answered = false
    @State private var isSaving = false
    @State private var hitFreeLimit = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xl) {
                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
                    Text("Do you own something similar?")
                        .font(BeforeTheme.Typeface.hero)
                        .tracking(BeforeTheme.displayTracking)
                        .foregroundStyle(BeforeTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("You don't need to add your whole closet. BEFORE learns as you shop.")
                        .font(BeforeTheme.Typeface.callout)
                        .foregroundStyle(BeforeTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, BeforeTheme.Spacing.l)

                HStack(spacing: BeforeTheme.Spacing.m) {
                    BeforeSecondaryButton("No") { dismiss() }
                    BeforeButton("Yes", isLoading: isSaving) {
                        Task { await recordOwnedSimilar() }
                    }
                }

                if hitFreeLimit {
                    Text("Your free wardrobe is full. BEFORE Plus remembers everything you own.")
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .beforeScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(280)])
    }

    /// Records the category, not the product — and sends it to the server.
    ///
    /// "I own something like this" is a statement about a KIND of thing, so the
    /// kind is what gets stored. Copying the candidate's name and price would
    /// record an item the user does not actually own and then use it to judge
    /// their next purchase — a fabricated fact with consequences.
    ///
    /// The server write is the point: a local-only item changes nothing about a
    /// future verdict, because the wardrobe signal is computed server-side.
    private func recordOwnedSimilar() async {
        guard !answered else { return }
        answered = true
        isSaving = true
        defer { isSaving = false }

        let draft = WardrobeDraft.fromSimilarProduct(analysis)

        do {
            let saved = try await environment.wardrobe.add(draft)

            // Mirror locally so the wardrobe reads correctly offline.
            modelContext.insert(
                CachedWardrobeItem(
                    id: saved.id,
                    categoryRaw: saved.category.rawValue,
                    subcategory: saved.subcategory,
                    color: saved.color,
                    brand: saved.brand,
                    price: saved.price,
                    currency: saved.currency,
                    styleTags: saved.styleTags
                )
            )
            try? modelContext.save()

            Analytics.track(
                .wardrobeItemAdded,
                AnalyticsProperties(category: analysis.product.category, context: "similar_prompt")
            )
            dismiss()
        } catch APIError.quotaExceeded {
            // Not an error — an offer. The sheet stays open to explain.
            answered = false
            hitFreeLimit = true
        } catch {
            // A failed sync must not lose the answer: keep it locally and let
            // the next wardrobe load reconcile.
            modelContext.insert(
                CachedWardrobeItem(
                    id: UUID().uuidString,
                    categoryRaw: analysis.product.category.rawValue,
                    subcategory: analysis.product.subcategory,
                    color: analysis.visual.colors.first,
                    styleTags: analysis.visual.styleTags
                )
            )
            try? modelContext.save()
            dismiss()
        }
    }
}

#Preview("Outcome") {
    OutcomeSheet(analysis: Fixtures.leatherJacket) { _ in }
}

#Preview("Own something similar") {
    OwnSomethingSimilarSheet(analysis: Fixtures.leatherJacket)
        .environment(AppEnvironment.preview)
        .modelContainer(LocalStore.makeContainer(inMemory: true))
}
