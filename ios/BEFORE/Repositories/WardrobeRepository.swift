import Foundation
import BeforeKit

// =============================================================================
// BEFORE — wardrobe repository.
//
// Until an item reaches the server it changes nothing about a verdict, so this
// is not an optional nicety: it is what connects "do you own something similar?"
// to the duplication signal that makes BEFORE say BYE.
// =============================================================================

public struct WardrobeDraft: Encodable, Sendable {
    public var category: String
    public var subcategory: String?
    public var color: String?
    public var brand: String?
    public var price: Double?
    public var currency: String?
    public var purchaseDate: String?
    public var styleTags: [String]?
    public var notes: String?
    public var imagePath: String?
    public var source: String?

    public init(
        category: ProductCategory = .fashion,
        subcategory: String? = nil,
        color: String? = nil,
        brand: String? = nil,
        price: Double? = nil,
        currency: String? = nil,
        purchaseDate: String? = nil,
        styleTags: [String]? = nil,
        notes: String? = nil,
        imagePath: String? = nil,
        source: String? = nil
    ) {
        self.category = category.rawValue
        self.subcategory = subcategory
        self.color = color
        self.brand = brand
        self.price = price
        self.currency = currency
        self.purchaseDate = purchaseDate
        self.styleTags = styleTags
        self.notes = notes
        self.imagePath = imagePath
        self.source = source
    }

    /// What BEFORE learned about a product, recorded as a thing the user owns.
    ///
    /// Deliberately drops the candidate's name and price: "I own something like
    /// this" is a statement about a KIND of thing. Copying the price would
    /// record a purchase that never happened and then use it to judge the next
    /// one — a fabricated fact with consequences.
    public static func fromSimilarProduct(_ analysis: Analysis) -> WardrobeDraft {
        WardrobeDraft(
            category: analysis.product.category,
            subcategory: analysis.product.subcategory,
            color: analysis.visual.colors.first,
            styleTags: Array(analysis.visual.styleTags.prefix(6)),
            source: "analysis"
        )
    }
}

public protocol WardrobeRepositoryProtocol: Sendable {
    func list() async throws -> WardrobeSnapshot
    func add(_ draft: WardrobeDraft) async throws -> WardrobeItem
    func update(id: String, draft: WardrobeDraft) async throws -> WardrobeItem
    func delete(id: String) async throws
}

public struct WardrobeRepository: WardrobeRepositoryProtocol {
    private let client: APIClientProtocol

    public init(client: APIClientProtocol) { self.client = client }

    public func list() async throws -> WardrobeSnapshot {
        try await client.send(.get("wardrobe"), as: WardrobeSnapshot.self)
    }

    public func add(_ draft: WardrobeDraft) async throws -> WardrobeItem {
        try await client.send(try APIRequest.post("wardrobe", body: draft), as: WardrobeItem.self)
    }

    public func update(id: String, draft: WardrobeDraft) async throws -> WardrobeItem {
        try await client.send(try APIRequest.patch("wardrobe/\(id)", body: draft), as: WardrobeItem.self)
    }

    public func delete(id: String) async throws {
        try await client.send(APIRequest(method: .delete, path: "wardrobe/\(id)"))
    }
}

// MARK: - Mock

public actor MockWardrobeRepository: WardrobeRepositoryProtocol {
    private var items: [WardrobeItem]
    private let limit: Int?

    public init(items: [WardrobeItem] = MockWardrobeRepository.sample, limit: Int? = 25) {
        self.items = items
        self.limit = limit
    }

    public func list() async throws -> WardrobeSnapshot {
        WardrobeSnapshot(items: items, limit: limit)
    }

    public func add(_ draft: WardrobeDraft) async throws -> WardrobeItem {
        if let limit, items.count >= limit { throw APIError.quotaExceeded }
        let item = WardrobeItem(
            id: UUID().uuidString,
            category: ProductCategory(rawValue: draft.category) ?? .fashion,
            subcategory: draft.subcategory,
            color: draft.color,
            brand: draft.brand,
            price: draft.price,
            currency: draft.currency,
            purchaseDate: draft.purchaseDate,
            styleTags: draft.styleTags ?? [],
            notes: draft.notes,
            source: draft.source ?? "manual"
        )
        items.insert(item, at: 0)
        return item
    }

    public func update(id: String, draft: WardrobeDraft) async throws -> WardrobeItem {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw APIError.notFound }
        var item = items[index]
        item.category = ProductCategory(rawValue: draft.category) ?? item.category
        item.subcategory = draft.subcategory
        item.color = draft.color
        item.brand = draft.brand
        item.price = draft.price
        item.currency = draft.currency
        item.styleTags = draft.styleTags ?? item.styleTags
        item.notes = draft.notes
        items[index] = item
        return item
    }

    public func delete(id: String) async throws {
        items.removeAll { $0.id == id }
    }

    public static let sample: [WardrobeItem] = [
        WardrobeItem(id: "w1", subcategory: "outerwear", color: "black", price: 210, currency: "USD",
                     styleTags: ["minimal", "edgy"]),
        WardrobeItem(id: "w2", subcategory: "outerwear", color: "black", price: 165, currency: "USD",
                     styleTags: ["classic"], source: "analysis"),
        WardrobeItem(id: "w3", subcategory: "outerwear", color: "camel", price: 240, currency: "USD",
                     styleTags: ["classic"]),
        WardrobeItem(id: "w4", subcategory: "tops", color: "black", price: 60, currency: "USD",
                     styleTags: ["minimal"]),
        WardrobeItem(id: "w5", subcategory: "tops", color: "white", price: 55, currency: "USD",
                     styleTags: ["minimal"]),
        WardrobeItem(id: "w6", subcategory: "shoes", color: "black", price: 180, currency: "USD",
                     styleTags: ["classic"]),
        WardrobeItem(id: "w7", subcategory: "bags", color: "brown", price: 260, currency: "USD",
                     styleTags: ["classic"]),
    ]
}
