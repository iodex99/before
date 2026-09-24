import SwiftData
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — Saved (spec §27).
//
// Three buckets: Maybe, Bought, Owned. Reads entirely from the local cache, so
// it opens instantly and works offline (spec §48).
// =============================================================================

struct SavedView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<CachedAnalysis> { $0.savedBucketRaw != nil },
        sort: \CachedAnalysis.createdAt,
        order: .reverse
    )
    private var saved: [CachedAnalysis]

    @State private var bucket: SavedBucket = .maybe

    private var visible: [CachedAnalysis] {
        saved.filter { $0.savedBucketRaw == bucket.rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: BeforeTheme.Spacing.l) {
                Picker("Bucket", selection: $bucket) {
                    ForEach(SavedBucket.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, BeforeTheme.Spacing.s)

                if bucket == .owned {
                    // "Owned" IS the wardrobe. Keeping them as two separate
                    // lists would mean two answers to "what do I own", and the
                    // navigation is fixed at four tabs (spec §8).
                    WardrobeView()
                } else if visible.isEmpty {
                    Spacer()
                    EmptyState(
                        title: emptyTitle,
                        message: emptyMessage,
                        systemImage: "bookmark"
                    )
                    Spacer()
                } else {
                    List {
                        ForEach(visible) { item in
                            NavigationLink {
                                destination(for: item)
                            } label: {
                                row(for: item)
                            }
                            .listRowBackground(BeforeTheme.background)
                            .listRowSeparatorTint(BeforeTheme.divider)
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .beforeScreen()
            .navigationTitle("Saved")
            .toolbar {
                if bucket != .owned && !visible.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func row(for item: CachedAnalysis) -> some View {
        if let analysis = item.analysis {
            AnalysisRow(analysis)
        } else {
            CachedRowFallback(item: item)
        }
    }

    @ViewBuilder
    private func destination(for item: CachedAnalysis) -> some View {
        if let analysis = item.analysis {
            ResultView(analysis: analysis, isRevisit: true)
        } else {
            ErrorState(message: "This one couldn't be reopened offline.")
                .beforeScreen()
        }
    }

    private var emptyTitle: String {
        switch bucket {
        case .maybe: "Nothing on your maybe list yet."
        case .bought: "Nothing marked bought yet."
        case .owned: "You don't need to add your whole closet."
        }
    }

    private var emptyMessage: String {
        switch bucket {
        case .maybe: "When something catches your eye, send it to BEFORE."
        case .bought: "Tell BEFORE what you actually bought and it gets better at advising you."
        case .owned: "BEFORE learns as you shop."
        }
    }

    private func delete(at offsets: IndexSet) {
        // Removes it from the list, not from history — the decision itself is
        // still part of the user's shopping memory.
        for index in offsets {
            visible[index].savedBucketRaw = nil
        }
        try? modelContext.save()
    }
}

#Preview("Saved") {
    SavedView().modelContainer(LocalStore.makeContainer(inMemory: true))
}
