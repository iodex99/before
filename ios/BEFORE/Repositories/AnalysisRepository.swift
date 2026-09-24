import Foundation
import BeforeKit

// =============================================================================
// BEFORE — repositories.
//
// The seam between features and the network. ViewModels depend on these
// protocols, so every screen can be driven from fixtures in a test or a preview
// without a server (spec §85).
// =============================================================================

public struct AnalysisRequestDraft: Sendable, Identifiable {
    /// The idempotency key doubles as the identity of this attempt, so
    /// presenting the flow twice for the same intent is impossible.
    public var id: String { idempotencyKey }

    /// Storage path of an already-uploaded image, if there is one.
    public var imagePath: String?
    /// Processed bytes waiting to be uploaded. Held until the upload succeeds
    /// so a dropped connection never loses the user's photo (spec §48).
    public var imageData: Data?
    public var productUrl: String?
    public var userNote: String?
    public var inputType: InputType
    public var categoryHint: ProductCategory?
    public var subcategoryHint: String?
    /// Generated once per user intent, reused across retries (spec §50).
    public let idempotencyKey: String

    public init(
        imagePath: String? = nil,
        imageData: Data? = nil,
        productUrl: String? = nil,
        userNote: String? = nil,
        inputType: InputType,
        categoryHint: ProductCategory? = nil,
        subcategoryHint: String? = nil,
        idempotencyKey: String = UUID().uuidString
    ) {
        self.imagePath = imagePath
        self.imageData = imageData
        self.productUrl = productUrl
        self.userNote = userNote
        self.inputType = inputType
        self.categoryHint = categoryHint
        self.subcategoryHint = subcategoryHint
        self.idempotencyKey = idempotencyKey
    }
}

public struct OutcomeDraft: Sendable, Encodable {
    public var action: OutcomeAction
    public var purchaseDate: String?
    public var actualPrice: Double?
    public var currency: String?
    public var returned: Bool
    public var satisfaction: Satisfaction?
    public var notes: String?

    public init(
        action: OutcomeAction,
        purchaseDate: String? = nil,
        actualPrice: Double? = nil,
        currency: String? = nil,
        returned: Bool = false,
        satisfaction: Satisfaction? = nil,
        notes: String? = nil
    ) {
        self.action = action
        self.purchaseDate = purchaseDate
        self.actualPrice = actualPrice
        self.currency = currency
        self.returned = returned
        self.satisfaction = satisfaction
        self.notes = notes
    }
}

public protocol AnalysisRepositoryProtocol: Sendable {
    func analyse(_ draft: AnalysisRequestDraft) async throws -> Analysis
    func analysis(id: String) async throws -> Analysis
    func recordOutcome(analysisId: String, outcome: OutcomeDraft) async throws
    func usage() async throws -> UsageSnapshot
    func productMetadata(for url: String) async throws -> ProductPreview
    func explain(analysisId: String, angle: ExplanationAngle) async throws -> String
}

/// The only questions a deeper explanation may be asked.
///
/// A closed set rather than free text: Rule 1 says BEFORE is not a general AI
/// assistant, and a text field on the result screen is how it would become one.
public enum ExplanationAngle: String, Codable, Sendable, CaseIterable, Identifiable {
    case whyThisVerdict = "why_this_verdict"
    case whatWouldChangeIt = "what_would_change_it"
    case howItFits = "how_it_fits"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .whyThisVerdict: "Why this verdict?"
        case .whatWouldChangeIt: "What would change it?"
        case .howItFits: "How would it fit?"
        }
    }
}

public struct ProductPreview: Codable, Sendable, Equatable {
    public struct Metadata: Codable, Sendable, Equatable {
        public var title: String?
        public var brand: String?
        public var price: Double?
        public var currency: String?
        public var imageUrl: String?
        public var retailer: String?
        /// False when the values came from a page title rather than structured
        /// data — the UI must not present those as confirmed facts.
        public var structured: Bool
    }

    public var url: String
    public var metadata: Metadata
    public var cached: Bool
}

// MARK: - Live

public struct AnalysisRepository: AnalysisRepositoryProtocol {
    private let client: APIClientProtocol

    public init(client: APIClientProtocol) {
        self.client = client
    }

    public func analyse(_ draft: AnalysisRequestDraft) async throws -> Analysis {
        struct Body: Encodable {
            let imagePath: String?
            let productUrl: String?
            let userNote: String?
            let inputType: String
            let categoryHint: String?
            let subcategoryHint: String?
        }

        let request = try APIRequest.post(
            "analyze-purchase",
            body: Body(
                imagePath: draft.imagePath,
                productUrl: draft.productUrl,
                userNote: draft.userNote,
                inputType: draft.inputType.rawValue,
                categoryHint: draft.categoryHint?.rawValue,
                subcategoryHint: draft.subcategoryHint
            ),
            idempotencyKey: draft.idempotencyKey,
            // The model call dominates this. A short timeout here just turns a
            // slow success into a failure the user pays a quota unit for.
            timeout: 75
        )

        return try await client.send(request, as: Analysis.self)
    }

    public func analysis(id: String) async throws -> Analysis {
        try await client.send(.get("analysis/\(id)"), as: Analysis.self)
    }

    public func recordOutcome(analysisId: String, outcome: OutcomeDraft) async throws {
        try await client.send(APIRequest.post("analysis/\(analysisId)/outcome", body: outcome))
    }

    public func usage() async throws -> UsageSnapshot {
        try await client.send(.get("usage"), as: UsageSnapshot.self)
    }

    public func productMetadata(for url: String) async throws -> ProductPreview {
        struct Body: Encodable { let url: String }
        return try await client.send(
            try APIRequest.post("product-metadata", body: Body(url: url)),
            as: ProductPreview.self
        )
    }

    public func explain(analysisId: String, angle: ExplanationAngle) async throws -> String {
        struct Body: Encodable { let angle: String }
        struct Response: Decodable { let explanation: String }

        let response = try await client.send(
            try APIRequest.post("explain/(analysisId)", body: Body(angle: angle.rawValue), timeout: 40),
            as: Response.self
        )
        return response.explanation
    }
}

// MARK: - Profile

public protocol ProfileRepositoryProtocol: Sendable {
    func me() async throws -> UserProfile
    func updatePreferences(_ update: ProfileUpdate) async throws -> UserProfile
    func deleteAccount() async throws
    /// The full server-side export (spec §43). Returns the raw JSON document.
    func exportData() async throws -> Data
}

public struct ProfileUpdate: Encodable, Sendable {
    public var preferredName: String?
    public var locale: String?
    public var currency: String?
    public var timezone: String?
    public var shoppingPriorities: [String]?
    public var favoriteStyles: [String]?
    public var budgetSensitivity: String?
    public var shoppingFocus: String?
    public var onboardingCompleted: Bool?

    public init(
        preferredName: String? = nil,
        locale: String? = nil,
        currency: String? = nil,
        timezone: String? = nil,
        shoppingPriorities: [ShoppingPriority]? = nil,
        favoriteStyles: [StylePreference]? = nil,
        budgetSensitivity: BudgetSensitivity? = nil,
        shoppingFocus: ShoppingFocus? = nil,
        onboardingCompleted: Bool? = nil
    ) {
        self.preferredName = preferredName
        self.locale = locale
        self.currency = currency
        self.timezone = timezone
        self.shoppingPriorities = shoppingPriorities?.map(\.rawValue)
        self.favoriteStyles = favoriteStyles?.map(\.rawValue)
        self.budgetSensitivity = budgetSensitivity?.rawValue
        self.shoppingFocus = shoppingFocus?.rawValue
        self.onboardingCompleted = onboardingCompleted
    }

    /// The device's own settings, so currency and dates are right without
    /// asking the user anything (spec §3, §62).
    public static func fromDeviceSettings() -> ProfileUpdate {
        var update = ProfileUpdate()
        update.locale = Locale.current.identifier
        update.currency = Locale.current.currency?.identifier
        update.timezone = TimeZone.current.identifier
        return update
    }
}

public struct ProfileRepository: ProfileRepositoryProtocol {
    private let client: APIClientProtocol

    public init(client: APIClientProtocol) { self.client = client }

    public func me() async throws -> UserProfile {
        try await client.send(.get("me"), as: UserProfile.self)
    }

    public func updatePreferences(_ update: ProfileUpdate) async throws -> UserProfile {
        try await client.send(try APIRequest.patch("me", body: update), as: UserProfile.self)
    }

    public func deleteAccount() async throws {
        struct Body: Encodable { let confirmation = "DELETE" }
        try await client.send(try APIRequest.post("account-delete", body: Body()))
    }

    public func exportData() async throws -> Data {
        try await client.sendRaw(.get("account-export"))
    }
}
