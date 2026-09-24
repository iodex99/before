import Foundation
import SwiftData
import BeforeKit

// =============================================================================
// BEFORE — local persistence.
//
// SwiftData is a CACHE, not a source of truth. The server owns account data;
// these models exist so History and Saved open instantly and still work on a
// plane (spec §47, §48).
//
// Nothing secret is stored here. Tokens live in the Keychain.
// =============================================================================

@Model
public final class CachedAnalysis {
    @Attribute(.unique) public var analysisId: String
    public var createdAt: Date
    public var productName: String?
    public var brand: String?
    public var categoryRaw: String
    public var price: Double?
    public var currency: String?
    public var verdictRaw: String
    public var score: Int
    public var confidence: Double
    public var imageURLString: String?
    /// The full API payload, so reopening an analysis offline shows the real
    /// factor breakdown rather than a stub.
    public var payload: Data?
    public var savedBucketRaw: String?
    public var outcomeActionRaw: String?
    public var cachedAt: Date

    public init(
        analysisId: String,
        createdAt: Date,
        productName: String?,
        brand: String?,
        categoryRaw: String,
        price: Double?,
        currency: String?,
        verdictRaw: String,
        score: Int,
        confidence: Double,
        imageURLString: String?,
        payload: Data?,
        savedBucketRaw: String? = nil,
        outcomeActionRaw: String? = nil,
        cachedAt: Date = .now
    ) {
        self.analysisId = analysisId
        self.createdAt = createdAt
        self.productName = productName
        self.brand = brand
        self.categoryRaw = categoryRaw
        self.price = price
        self.currency = currency
        self.verdictRaw = verdictRaw
        self.score = score
        self.confidence = confidence
        self.imageURLString = imageURLString
        self.payload = payload
        self.savedBucketRaw = savedBucketRaw
        self.outcomeActionRaw = outcomeActionRaw
        self.cachedAt = cachedAt
    }

    public var verdict: Verdict { Verdict(rawValue: verdictRaw) ?? .wait }
    public var category: ProductCategory { ProductCategory(rawValue: categoryRaw) ?? .other }
    public var savedBucket: SavedBucket? { savedBucketRaw.flatMap(SavedBucket.init(rawValue:)) }

    /// The full analysis, when the cached payload can still be decoded.
    public var analysis: Analysis? {
        guard let payload else { return nil }
        return try? JSON.decoder.decode(Analysis.self, from: payload)
    }

    public static func from(_ analysis: Analysis, bucket: SavedBucket? = nil) -> CachedAnalysis {
        CachedAnalysis(
            analysisId: analysis.analysisId,
            createdAt: analysis.createdAt,
            productName: analysis.product.name,
            brand: analysis.product.brand,
            categoryRaw: analysis.product.category.rawValue,
            price: analysis.product.price,
            currency: analysis.product.currency,
            verdictRaw: analysis.verdict.rawValue,
            score: analysis.score,
            confidence: analysis.confidence,
            imageURLString: analysis.imageUrl,
            payload: try? JSON.encoder.encode(analysis),
            savedBucketRaw: bucket?.rawValue
        )
    }
}

/// An image the user submitted that has not reached the server yet.
///
/// Spec §48: never silently discard a pending upload. If the network drops
/// between "user picked a photo" and "analysis returned", the bytes survive
/// here and the app offers to try again.
@Model
public final class PendingUpload {
    @Attribute(.unique) public var id: UUID
    /// Reused across retries so a retry cannot double-charge the quota (§50).
    public var idempotencyKey: String
    public var imageData: Data?
    public var productUrlString: String?
    public var userNote: String?
    public var inputTypeRaw: String
    public var createdAt: Date
    public var attemptCount: Int
    public var lastErrorMessage: String?

    public init(
        id: UUID = UUID(),
        idempotencyKey: String = UUID().uuidString,
        imageData: Data?,
        productUrlString: String?,
        userNote: String? = nil,
        inputTypeRaw: String,
        createdAt: Date = .now,
        attemptCount: Int = 0,
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.imageData = imageData
        self.productUrlString = productUrlString
        self.userNote = userNote
        self.inputTypeRaw = inputTypeRaw
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastErrorMessage = lastErrorMessage
    }

    public var inputType: InputType { InputType(rawValue: inputTypeRaw) ?? .photo }
}

/// A wardrobe item held locally so "do you own something similar?" works
/// immediately after an analysis, before a round trip completes.
@Model
public final class CachedWardrobeItem {
    @Attribute(.unique) public var id: String
    public var categoryRaw: String
    public var subcategory: String?
    public var color: String?
    public var brand: String?
    public var price: Double?
    public var currency: String?
    public var styleTags: [String]
    public var imageURLString: String?
    public var createdAt: Date

    public init(
        id: String,
        categoryRaw: String,
        subcategory: String? = nil,
        color: String? = nil,
        brand: String? = nil,
        price: Double? = nil,
        currency: String? = nil,
        styleTags: [String] = [],
        imageURLString: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.categoryRaw = categoryRaw
        self.subcategory = subcategory
        self.color = color
        self.brand = brand
        self.price = price
        self.currency = currency
        self.styleTags = styleTags
        self.imageURLString = imageURLString
        self.createdAt = createdAt
    }

    public var category: ProductCategory { ProductCategory(rawValue: categoryRaw) ?? .other }
}

// MARK: - Container

public enum LocalStore {
    public static let schema = Schema([
        CachedAnalysis.self,
        PendingUpload.self,
        CachedWardrobeItem.self,
    ])

    /// The app's container. In-memory under UI tests so every run starts clean.
    public static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory || AppConfig.isUITesting
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A cache that cannot open must not take the app down with it.
            // Fall back to memory: the user loses offline history, not access.
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            guard let container = try? ModelContainer(for: schema, configurations: [fallback]) else {
                fatalError("Unable to create a SwiftData container: \(error)")
            }
            return container
        }
    }
}
