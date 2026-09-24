import Social
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// =============================================================================
// BEFORE — share extension.
//
// From Instagram, Safari, Pinterest, or any shop: Share -> BEFORE.
//
// The extension does the least possible work (spec §13). It writes a payload
// into the App Group container and finishes. It holds no credentials, makes no
// network call, and never touches the Keychain — a share sheet that hangs for
// two seconds feels broken, and a second process with an auth token is a second
// place for one to leak.
// =============================================================================

final class ShareViewController: UIViewController {

    private let inbox = SharedInbox(appGroupIdentifier: ShareExtensionConfig.appGroupIdentifier)
    private var hostingController: UIHostingController<ShareStatusView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        presentStatus(.working)
        Task { await handleInput() }
    }

    // MARK: - Extraction

    private func handleInput() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            await finish(.unsupported)
            return
        }

        // First usable attachment wins. Order of preference: image, then URL,
        // then text containing a URL.
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let data = await loadImageData(from: provider) {
                    await save(.init(kind: .image, imageFilename: "\(UUID().uuidString).jpg"), imageData: data)
                    return
                }
            }
        }

        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await loadURL(from: provider) {
                    await save(.init(kind: .url, urlString: url.absoluteString))
                    return
                }
            }
        }

        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = await loadText(from: provider) {
                    let payload = SharedLinkDetector.payload(forText: text)
                    // Plain text with no link in it is nothing BEFORE can check.
                    guard payload.kind == .url else { continue }
                    await save(payload)
                    return
                }
            }
        }

        await finish(.unsupported)
    }

    private func loadImageData(from provider: NSItemProvider) async -> Data? {
        // Providers hand back a UIImage, a Data, or a file URL depending on the
        // source app. All three are normal; all three are handled.
        if let data = try? await provider.loadItem(
            forTypeIdentifier: UTType.image.identifier
        ) as? Data {
            return data
        }
        if let url = try? await provider.loadItem(
            forTypeIdentifier: UTType.image.identifier
        ) as? URL {
            return try? Data(contentsOf: url)
        }
        if let image = try? await provider.loadItem(
            forTypeIdentifier: UTType.image.identifier
        ) as? UIImage {
            return image.jpegData(compressionQuality: 0.9)
        }
        return nil
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        guard let url = try? await provider.loadItem(
            forTypeIdentifier: UTType.url.identifier
        ) as? URL else { return nil }
        // A file URL from another app's sandbox is not something we can use.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
    }

    // MARK: - Saving

    private func save(_ payload: SharedPayload, imageData: Data? = nil) async {
        do {
            // Shrink here rather than in the app: a 12MP screenshot sitting in
            // the shared container is wasted space, and the extension has a
            // tight memory budget to respect.
            let prepared = imageData.flatMap { ShareImageReducer.reduce($0) } ?? imageData
            try inbox.write(payload, imageData: prepared)
            await finish(.saved)
        } catch {
            await finish(.failed)
        }
    }

    // MARK: - UI

    @MainActor
    private func presentStatus(_ status: ShareStatusView.Status) {
        if let hostingController {
            hostingController.rootView = ShareStatusView(status: status)
            return
        }
        let controller = UIHostingController(rootView: ShareStatusView(status: status))
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        hostingController = controller
    }

    @MainActor
    private func finish(_ result: Result) async {
        presentStatus(result.status)

        // Long enough to read, short enough not to be in the way.
        try? await Task.sleep(for: .milliseconds(result == .saved ? 700 : 1400))

        if result == .saved {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(
                withError: NSError(
                    domain: "com.yourcompany.before.share",
                    code: result == .unsupported ? 1 : 2
                )
            )
        }
    }

    private enum Result: Equatable {
        case saved, unsupported, failed

        var status: ShareStatusView.Status {
            switch self {
            case .saved: .saved
            case .unsupported: .unsupported
            case .failed: .failed
            }
        }
    }
}

// =============================================================================

struct ShareStatusView: View {
    enum Status: Equatable {
        case working, saved, unsupported, failed

        var title: String {
            switch self {
            case .working: "Sending to BEFORE…"
            case .saved: "Sent to BEFORE"
            case .unsupported: "BEFORE can't check that"
            case .failed: "That didn't save"
            }
        }

        var detail: String? {
            switch self {
            case .working: nil
            case .saved: "Open BEFORE to see the verdict."
            case .unsupported: "Try sharing a photo, a screenshot, or a product link."
            case .failed: "Try sharing it again."
            }
        }

        var systemImage: String {
            switch self {
            case .working: "arrow.up.circle"
            case .saved: "checkmark.circle.fill"
            case .unsupported: "questionmark.circle"
            case .failed: "exclamationmark.triangle"
            }
        }
    }

    let status: Status

    var body: some View {
        VStack(spacing: 14) {
            if status == .working {
                ProgressView()
            } else {
                Image(systemName: status.systemImage)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(status == .saved ? Color.green : Color.secondary)
            }

            Text("BEFORE")
                .font(.system(size: 12, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.secondary)

            Text(status.title)
                .font(.headline)
                .multilineTextAlignment(.center)

            if let detail = status.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .combine)
    }
}

// =============================================================================

/// The extension cannot read the app's Info.plist, so the App Group id is
/// injected into its own via the shared xcconfig. See docs/SETUP.md.
enum ShareExtensionConfig {
    static var appGroupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String
            ?? "group.com.yourcompany.before"
    }
}

/// A minimal downsampler.
///
/// The app's ImageProcessor is not used here on purpose: it pulls in the full
/// app module, and a share extension has a much smaller memory budget than an
/// app. This does the one thing that matters — keep the shared container small.
enum ShareImageReducer {
    static func reduce(_ data: Data, maxPixelSize: CGFloat = 2200) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return data }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return data
        }
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85) ?? data
    }
}
