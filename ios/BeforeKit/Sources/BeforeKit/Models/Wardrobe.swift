import Foundation

// =============================================================================
// BEFORE — wardrobe.
//
// What the user owns. This is the input to the heaviest signal in the score
// (wardrobe compatibility, 25%) and the only thing that lets BEFORE say
// "you already own two of these".
//
// Mirrors the `wardrobe_items` table and the /v1/wardrobe contract.
// =============================================================================

public struct WardrobeItem: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var category: ProductCategory
    public var subcategory: String?
    public var color: String?
    public var brand: String?
    public var price: Double?
    public var currency: String?
    /// ISO `YYYY-MM-DD`, or nil. A plain date, not a timestamp — nobody knows
    /// what time of day they bought a jumper.
    public var purchaseDate: String?
    public var styleTags: [String]
    public var notes: String?
    public var imagePath: String?
    /// `manual` when added directly, `analysis` when created from a
    /// "do you own something similar?" answer.
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        category: ProductCategory = .fashion,
        subcategory: String? = nil,
        color: String? = nil,
        brand: String? = nil,
        price: Double? = nil,
        currency: String? = nil,
        purchaseDate: String? = nil,
        styleTags: [String] = [],
        notes: String? = nil,
        imagePath: String? = nil,
        source: String = "manual",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.category = category
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decodeIfPresent(ProductCategory.self, forKey: .category) ?? .fashion
        subcategory = try c.decodeIfPresent(String.self, forKey: .subcategory)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        price = try c.decodeIfPresent(Double.self, forKey: .price)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        purchaseDate = try c.decodeIfPresent(String.self, forKey: .purchaseDate)
        styleTags = try c.decodeIfPresent([String].self, forKey: .styleTags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }

    /// What to show as the item's name. Never invents a brand it does not have.
    public var displayName: String {
        let descriptor = [color?.capitalized, subcategory?.capitalized]
            .compactMap { $0 }
            .joined(separator: " ")

        if let brand, !brand.isEmpty {
            return descriptor.isEmpty ? brand : "\(brand) \(descriptor.lowercased())"
        }
        return descriptor.isEmpty ? category.rawValue.capitalized : descriptor
    }

    /// The secondary line: tags, or the price, or nothing.
    public var detailLine: String? {
        if !styleTags.isEmpty { return styleTags.prefix(3).joined(separator: " · ") }
        if let formatted = Formatting.price(price, currencyCode: currency) { return formatted }
        return nil
    }
}

/// The list response, which also carries the free-plan cap.
public struct WardrobeSnapshot: Codable, Sendable, Equatable {
    public var items: [WardrobeItem]
    /// nil for Plus — no cap.
    public var limit: Int?

    public init(items: [WardrobeItem], limit: Int?) {
        self.items = items
        self.limit = limit
    }

    public var isAtLimit: Bool {
        guard let limit else { return false }
        return items.count >= limit
    }

    /// "18 of 25" — nil for Plus, which has no number to show.
    public var capacityDescription: String? {
        guard let limit else { return nil }
        return "\(items.count) of \(limit)"
    }

    /// Grouped for display, most-populated group first so the list opens on
    /// something useful rather than on whichever category sorts first.
    public var grouped: [(key: String, items: [WardrobeItem])] {
        let groups = Dictionary(grouping: items) { item in
            item.subcategory?.capitalized ?? item.category.rawValue.capitalized
        }
        return groups
            .map { (key: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { lhs, rhs in
                lhs.items.count == rhs.items.count
                    ? lhs.key < rhs.key
                    : lhs.items.count > rhs.items.count
            }
    }
}
