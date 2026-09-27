import Foundation

// =============================================================================
// BEFORE — share extension handoff.
//
// Compiled into BOTH the app and the share extension (see project.yml).
//
// Architecture (spec §13):
//   Share sheet -> extension writes a payload into the App Group container
//                -> app launches, drains the inbox, deletes what it consumed.
//
// The extension does no network work and holds no credentials. It writes a
// file and gets out of the way, which keeps it fast enough that the share sheet
// does not feel broken, and keeps the auth token out of a second process.
// =============================================================================

/// Hashable so `CheckEntryPoint` — which carries one of these — can be, which
/// SwiftUI needs for `.sheet(item:)` and for enum equality in the check flow.
public struct SharedPayload: Codable, Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case image
        case url
        case text
    }

    public let id: UUID
    public let kind: Kind
    /// Present for `.url`, and for `.text` when a URL was found inside it.
    public let urlString: String?
    /// File name inside the inbox directory. Present for `.image`.
    public let imageFilename: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        urlString: String? = nil,
        imageFilename: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.urlString = urlString
        self.imageFilename = imageFilename
        self.createdAt = createdAt
    }
}

public enum SharedInboxError: LocalizedError {
    case appGroupUnavailable(String)
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            "The app group \(identifier) is not configured. See docs/SETUP.md."
        case .writeFailed:
            "That item couldn't be saved. Try sharing it again."
        }
    }
}

/// Reads and writes the shared inbox. Safe to use from either process.
public struct SharedInbox: Sendable {
    private let appGroupIdentifier: String
    private let fileManager = FileManager.default

    public init(appGroupIdentifier: String) {
        self.appGroupIdentifier = appGroupIdentifier
    }

    // MARK: - Locations

    private var containerURL: URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private func inboxURL() throws -> URL {
        guard let containerURL else {
            throw SharedInboxError.appGroupUnavailable(appGroupIdentifier)
        }
        let inbox = containerURL.appendingPathComponent("ShareInbox", isDirectory: true)
        if !fileManager.fileExists(atPath: inbox.path) {
            try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        return inbox
    }

    public var isAvailable: Bool { containerURL != nil }

    // MARK: - Writing (extension side)

    public func write(_ payload: SharedPayload, imageData: Data? = nil) throws {
        let inbox = try inboxURL()

        if let imageData, let filename = payload.imageFilename {
            try imageData.write(to: inbox.appendingPathComponent(filename), options: .atomic)
        }

        let manifest = inbox.appendingPathComponent("\(payload.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(payload).write(to: manifest, options: .atomic)
        } catch {
            throw SharedInboxError.writeFailed
        }
    }

    // MARK: - Reading (app side)

    /// Everything waiting, oldest first.
    ///
    /// A manifest that fails to decode is deleted rather than retried forever —
    /// a corrupt payload should not wedge the inbox on every launch.
    public func pendingPayloads() -> [SharedPayload] {
        guard let inbox = try? inboxURL(),
              let files = try? fileManager.contentsOfDirectory(
                  at: inbox,
                  includingPropertiesForKeys: nil
              )
        else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var payloads: [SharedPayload] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            if let payload = try? decoder.decode(SharedPayload.self, from: data) {
                payloads.append(payload)
            } else {
                try? fileManager.removeItem(at: file)
            }
        }
        return payloads.sorted { $0.createdAt < $1.createdAt }
    }

    public func imageData(for payload: SharedPayload) -> Data? {
        guard let filename = payload.imageFilename, let inbox = try? inboxURL() else { return nil }
        return try? Data(contentsOf: inbox.appendingPathComponent(filename))
    }

    /// Remove a payload and its image. Called only after a successful handoff.
    public func consume(_ payload: SharedPayload) {
        guard let inbox = try? inboxURL() else { return }
        try? fileManager.removeItem(at: inbox.appendingPathComponent("\(payload.id.uuidString).json"))
        if let filename = payload.imageFilename {
            try? fileManager.removeItem(at: inbox.appendingPathComponent(filename))
        }
    }

    /// Sweep anything left behind by an interrupted handoff.
    ///
    /// Spec §13: do not retain share-extension data unnecessarily. Without this,
    /// a crash between "extension wrote" and "app consumed" leaks an image into
    /// the container permanently.
    @discardableResult
    public func purgeStale(olderThan age: TimeInterval = 48 * 3600, now: Date = .now) -> Int {
        let cutoff = now.addingTimeInterval(-age)
        var removed = 0
        for payload in pendingPayloads() where payload.createdAt < cutoff {
            consume(payload)
            removed += 1
        }
        return removed
    }
}

// =============================================================================
// URL detection
//
// Shared sheets hand over wildly inconsistent content: a bare URL, a caption
// with a link buried in it, or an attributed string. This is deliberately
// permissive about the input and strict about the output.
// =============================================================================

public enum SharedLinkDetector {
    /// The first http(s) URL in a piece of text, if any.
    public static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url else { continue }
            if url.scheme == "http" || url.scheme == "https" { return url }
        }
        return nil
    }

    /// Build the right payload for a piece of shared text.
    public static func payload(forText text: String) -> SharedPayload {
        if let url = firstURL(in: text) {
            return SharedPayload(kind: .url, urlString: url.absoluteString)
        }
        return SharedPayload(kind: .text, urlString: nil)
    }
}
