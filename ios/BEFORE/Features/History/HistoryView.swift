import SwiftData
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — History (spec §28).
//
// Grouped by day, filterable by verdict. Uses a lazy list and a fetch limit so
// a heavy user's history never loads in one go (spec §81).
// =============================================================================

struct HistoryView: View {
    @Environment(AppEnvironment.self) private var environment

    @Query(sort: \CachedAnalysis.createdAt, order: .reverse)
    private var all: [CachedAnalysis]

    @State private var filter: Filter = .all
    @State private var visibleCount = HistoryView.pageSize

    private static let pageSize = 40

    enum Filter: String, CaseIterable, Identifiable {
        case all, buy, wait, bye
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .buy: "BUY"
            case .wait: "WAIT"
            case .bye: "BYE"
            }
        }

        var verdict: Verdict? {
            switch self {
            case .all: nil
            case .buy: .buy
            case .wait: .wait
            case .bye: .bye
            }
        }
    }

    private var filtered: [CachedAnalysis] {
        guard let verdict = filter.verdict else { return all }
        return all.filter { $0.verdict == verdict }
    }

    private var paged: [CachedAnalysis] { Array(filtered.prefix(visibleCount)) }

    /// Day sections, newest first.
    private var sections: [(date: Date, items: [CachedAnalysis])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: paged) { calendar.startOfDay(for: $0.createdAt) }
        return grouped
            .map { (date: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            Group {
                if all.isEmpty {
                    EmptyState(
                        title: "Your shopping decisions will live here.",
                        message: "Check your first item to start building your shopping memory.",
                        systemImage: "clock"
                    )
                    .frame(maxHeight: .infinity)
                } else if filtered.isEmpty {
                    EmptyState(
                        title: "Nothing here yet.",
                        message: "You haven't had a \(filter.title) verdict so far.",
                        systemImage: "line.3.horizontal.decrease"
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
            .beforeScreen()
            .navigationTitle("History")
            .safeAreaInset(edge: .top) { filterBar }
        }
    }

    private var filterBar: some View {
        Picker("Filter", selection: $filter) {
            ForEach(Filter.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, BeforeTheme.Spacing.gutter)
        .padding(.vertical, BeforeTheme.Spacing.s)
        .background(BeforeTheme.background)
        .onChange(of: filter) { _, _ in visibleCount = Self.pageSize }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BeforeTheme.Spacing.l, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.date) { section in
                    Section {
                        VStack(spacing: 0) {
                            ForEach(section.items) { item in
                                NavigationLink {
                                    destination(for: item)
                                } label: {
                                    row(for: item)
                                }
                                .buttonStyle(.plain)

                                if item.id != section.items.last?.id {
                                    Divider().overlay(BeforeTheme.divider)
                                }
                            }
                        }
                    } header: {
                        SectionHeader(Formatting.sectionDate(section.date))
                            .padding(.vertical, BeforeTheme.Spacing.xs)
                            .background(BeforeTheme.background)
                    }
                }

                if visibleCount < filtered.count {
                    // Page in more only when the user actually reaches the end.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BeforeTheme.Spacing.l)
                        .onAppear { visibleCount += Self.pageSize }
                }
            }
            .padding(.bottom, BeforeTheme.Spacing.xxl)
        }
    }

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
}

#Preview("History") {
    HistoryView()
        .environment(AppEnvironment.preview)
        .modelContainer(LocalStore.makeContainer(inMemory: true))
}
