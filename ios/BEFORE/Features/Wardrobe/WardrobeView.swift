import Observation
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — wardrobe.
//
// Lives inside the Saved tab's "Owned" bucket rather than a fifth tab (spec §8
// fixes the navigation at four).
//
// The empty state matters more than the list here: the product promise is that
// you do NOT have to digitise your closet, so this screen must never read as a
// chore waiting to be done (spec §26, §59).
// =============================================================================

@MainActor
@Observable
final class WardrobeViewModel {
    enum State: Equatable {
        case loading
        case loaded(WardrobeSnapshot)
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var isSaving = false

    private let repository: WardrobeRepositoryProtocol

    init(repository: WardrobeRepositoryProtocol) {
        self.repository = repository
    }

    var snapshot: WardrobeSnapshot? {
        if case .loaded(let snapshot) = state { return snapshot }
        return nil
    }

    func load() async {
        do {
            state = .loaded(try await repository.list())
        } catch {
            state = .failed((error as? APIError)?.userMessage ?? "We couldn't load your wardrobe.")
        }
    }

    /// Returns false when the free cap stopped it, so the caller can offer Plus
    /// rather than showing a failure.
    @discardableResult
    func add(_ draft: WardrobeDraft) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await repository.add(draft)
            await load()
            Analytics.track(
                .wardrobeItemAdded,
                AnalyticsProperties(
                    category: ProductCategory(rawValue: draft.category),
                    context: draft.source ?? "manual"
                )
            )
            return true
        } catch APIError.quotaExceeded {
            return false
        } catch {
            state = .failed((error as? APIError)?.userMessage ?? "We couldn't save that.")
            return false
        }
    }

    func update(id: String, draft: WardrobeDraft) async {
        isSaving = true
        defer { isSaving = false }
        _ = try? await repository.update(id: id, draft: draft)
        await load()
    }

    func delete(_ item: WardrobeItem) async {
        // Optimistic: removal should feel immediate, and a failed delete is
        // corrected by the reload that follows.
        if case .loaded(var snapshot) = state {
            snapshot.items.removeAll { $0.id == item.id }
            state = .loaded(snapshot)
        }
        try? await repository.delete(id: item.id)
        await load()
    }
}

// =============================================================================

struct WardrobeView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var model: WardrobeViewModel?
    @State private var editing: WardrobeItem?
    @State private var isAdding = false
    @State private var showingPaywall = false

    var body: some View {
        Group {
            switch model?.state {
            case .loading, .none:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                ErrorState(message: message, retry: { Task { await model?.load() } })

            case .loaded(let snapshot):
                if snapshot.items.isEmpty {
                    EmptyState(
                        title: "You don't need to add your whole closet.",
                        message: "BEFORE learns as you shop. Add a few pieces and it can tell you when something is a duplicate.",
                        systemImage: "tshirt",
                        actionTitle: "Add an item",
                        action: { isAdding = true }
                    )
                } else {
                    list(snapshot)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if model?.snapshot?.isAtLimit == true {
                        Analytics.track(.paywallViewed, AnalyticsProperties(context: "wardrobe_limit"))
                        showingPaywall = true
                    } else {
                        isAdding = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a wardrobe item")
                .accessibilityIdentifier("wardrobe.add")
            }
        }
        .sheet(isPresented: $isAdding) {
            WardrobeItemEditor(item: nil) { draft in
                Task {
                    let saved = await model?.add(draft) ?? false
                    if !saved { showingPaywall = true }
                }
            }
        }
        .sheet(item: $editing) { item in
            WardrobeItemEditor(item: item) { draft in
                Task { await model?.update(id: item.id, draft: draft) }
            }
        }
        .sheet(isPresented: $showingPaywall) { PaywallView(placement: "wardrobe_limit") }
        .task {
            if model == nil { model = WardrobeViewModel(repository: environment.wardrobe) }
            await model?.load()
        }
    }

    private func list(_ snapshot: WardrobeSnapshot) -> some View {
        List {
            ForEach(snapshot.grouped, id: \.key) { group in
                Section(group.key) {
                    ForEach(group.items) { item in
                        Button { editing = item } label: { row(item) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await model?.delete(item) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listRowBackground(BeforeTheme.surface)
            }

            if let capacity = snapshot.capacityDescription {
                Section {
                    HStack {
                        Text("\(capacity) items")
                            .font(BeforeTheme.Typeface.caption)
                            .foregroundStyle(BeforeTheme.secondaryText)
                        Spacer()
                        if snapshot.isAtLimit {
                            Button("Get more with Plus") { showingPaywall = true }
                                .font(BeforeTheme.Typeface.caption)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(_ item: WardrobeItem) -> some View {
        HStack(spacing: BeforeTheme.Spacing.m) {
            ProductThumbnail(urlString: nil, category: item.category, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(BeforeTheme.Typeface.body)
                    .foregroundStyle(BeforeTheme.primaryText)
                if let detail = item.detailLine {
                    Text(detail)
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.secondaryText)
                }
            }

            Spacer(minLength: 0)

            if item.source == "analysis" {
                // Shows where an item came from, so a wrong answer to
                // "do you own something similar?" is easy to find and remove.
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(BeforeTheme.tertiaryText)
                    .accessibilityLabel("Added from an analysis")
            }
        }
        .padding(.vertical, BeforeTheme.Spacing.xs)
        .contentShape(Rectangle())
    }
}

// =============================================================================

struct WardrobeItemEditor: View {
    let item: WardrobeItem?
    let onSave: (WardrobeDraft) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var category: ProductCategory = .fashion
    @State private var subcategory = ""
    @State private var color = ""
    @State private var brand = ""
    @State private var priceText = ""
    @State private var tagsText = ""

    private var isEditing: Bool { item != nil }

    /// Only fashion and beauty ship, so only those are offered (spec §96).
    private let categories: [ProductCategory] = [.fashion, .beauty, .accessory]

    private let fashionSubcategories = [
        "tops", "bottoms", "dresses", "outerwear", "shoes",
        "bags", "accessories", "activewear", "formalwear",
    ]
    private let beautySubcategories = ["makeup", "skincare", "haircare", "fragrance", "nails", "tools"]

    private var subcategories: [String] {
        category == .beauty ? beautySubcategories : fashionSubcategories
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What is it?") {
                    Picker("Category", selection: $category) {
                        ForEach(categories, id: \.self) { option in
                            Text(option.rawValue.capitalized).tag(option)
                        }
                    }

                    Picker("Type", selection: $subcategory) {
                        Text("Not specified").tag("")
                        ForEach(subcategories, id: \.self) { option in
                            Text(option.capitalized).tag(option)
                        }
                    }

                    TextField("Colour", text: $color)
                        .textInputAutocapitalization(.never)
                }

                Section("Optional") {
                    TextField("Brand", text: $brand)
                    HStack {
                        Text(environment.profile?.currency ?? "Price")
                            .foregroundStyle(BeforeTheme.secondaryText)
                        TextField("What you paid", text: $priceText)
                            .keyboardType(.decimalPad)
                    }
                    TextField("Tags, comma separated", text: $tagsText)
                        .textInputAutocapitalization(.never)
                }

                Section {
                    Text("BEFORE uses this to spot duplicates and judge whether something fits what you already own. Nothing here is shared.")
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.tertiaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(BeforeTheme.background.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit item" : "Add item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("wardrobe.save")
                }
            }
            .onAppear(perform: populate)
        }
    }

    private func populate() {
        guard let item else { return }
        category = item.category
        subcategory = item.subcategory ?? ""
        color = item.color ?? ""
        brand = item.brand ?? ""
        priceText = item.price.map { String(format: "%g", $0) } ?? ""
        tagsText = item.styleTags.joined(separator: ", ")
    }

    private func save() {
        // A price without a currency is rejected by the server, so it is only
        // sent when both are known.
        let price = Double(priceText.replacingOccurrences(of: ",", with: "."))
        let currency = environment.profile?.currency

        onSave(
            WardrobeDraft(
                category: category,
                subcategory: subcategory.isEmpty ? nil : subcategory,
                color: color.isEmpty ? nil : color.lowercased(),
                brand: brand.isEmpty ? nil : brand,
                price: currency == nil ? nil : price,
                currency: price == nil ? nil : currency,
                styleTags: tagsText
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty },
                source: item?.source
            )
        )
        dismiss()
    }
}

#Preview("Wardrobe") {
    NavigationStack { WardrobeView() }
        .environment(AppEnvironment.preview)
}
