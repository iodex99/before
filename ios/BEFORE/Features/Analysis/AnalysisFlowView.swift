import Observation
import SwiftData
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — the analysis flow.
//
// Upload -> analyse -> result. The three states this screen can be in are the
// three the spec insists on: staged loading, a real result, and a failure with
// something useful to do about it (spec §15, §45, §84).
// =============================================================================

@MainActor
@Observable
final class AnalysisFlowViewModel {

    enum Phase: Equatable {
        case working
        case finished(Analysis)
        case failed(APIError)
        /// Free allowance is gone. Distinct from an error: the answer is a
        /// paywall, not a retry button.
        case quotaExceeded
    }

    private(set) var phase: Phase = .working

    private var draft: AnalysisRequestDraft
    private let repository: AnalysisRepositoryProtocol
    private let uploader: ImageUploading
    private let userId: String
    private var task: Task<Void, Never>?

    init(
        draft: AnalysisRequestDraft,
        repository: AnalysisRepositoryProtocol,
        uploader: ImageUploading,
        userId: String
    ) {
        self.draft = draft
        self.repository = repository
        self.uploader = uploader
        self.userId = userId
    }

    deinit { task?.cancel() }

    func start() {
        guard task == nil else { return }
        Analytics.track(.analysisStarted, AnalyticsProperties(inputType: draft.inputType))
        run()
    }

    func retry() {
        // The idempotency key is deliberately NOT regenerated. If the first
        // attempt actually reached the server, this returns that same analysis
        // instead of paying for a second one (spec §50).
        phase = .working
        task = nil
        run()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run() {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Upload first, and only once: a retry after a failed analysis
                // reuses the path rather than re-uploading the same bytes.
                if draft.imagePath == nil, let imageData = draft.imageData {
                    draft.imagePath = try await uploader.uploadAnalysisImage(imageData, userId: userId)
                }

                try Task.checkCancellation()
                let analysis = try await repository.analyse(draft)

                try Task.checkCancellation()
                phase = .finished(analysis)
                Analytics.track(
                    .analysisCompleted,
                    AnalyticsProperties(
                        category: analysis.product.category,
                        verdict: analysis.verdict,
                        score: analysis.score,
                        inputType: draft.inputType
                    )
                )
            } catch is CancellationError {
                // Leaving the screen is not a failure worth reporting.
            } catch let error as APIError {
                phase = error == .quotaExceeded ? .quotaExceeded : .failed(error)
                Analytics.track(
                    .analysisFailed,
                    AnalyticsProperties(inputType: draft.inputType, context: String(describing: error))
                )
            } catch {
                phase = .failed(.analysisFailed)
                Analytics.track(.analysisFailed, AnalyticsProperties(inputType: draft.inputType))
            }
        }
    }
}

// =============================================================================

struct AnalysisFlowView: View {
    let draft: AnalysisRequestDraft

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var model: AnalysisFlowViewModel?
    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            Group {
                switch model?.phase {
                case .working, .none:
                    LoadingAnalysisView {
                        model?.cancel()
                        persistPendingUpload()
                        dismiss()
                    }

                case .finished(let analysis):
                    ResultView(analysis: analysis, isRevisit: false) { dismiss() }

                case .failed(let error):
                    ErrorState(
                        title: error == .urlUnreadable
                            ? "We couldn't read that page."
                            : "We couldn't finish that analysis.",
                        message: [error.userMessage, error.recoverySuggestion]
                            .compactMap { $0 }
                            .joined(separator: " "),
                        retry: error.isRetryable || error == .analysisFailed
                            ? { model?.retry() }
                            : nil,
                        cancel: {
                            persistPendingUpload()
                            dismiss()
                        }
                    )
                    .beforeScreen()

                case .quotaExceeded:
                    // Not framed as an error — it is an offer.
                    EmptyState(
                        title: "You've used all your checks this month.",
                        message: "BEFORE Plus gives you unlimited checks, and remembers more of what you own.",
                        systemImage: "sparkles",
                        actionTitle: "See BEFORE Plus",
                        action: { showingPaywall = true }
                    )
                    .beforeScreen()
                }
            }
            .toolbar {
                if case .finished = model?.phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            model?.cancel()
                            persistPendingUpload()
                            dismiss()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(placement: "analysis_quota")
        }
        .task {
            guard model == nil else { return }
            guard case .signedIn(let userId) = environment.auth.state else {
                dismiss()
                return
            }
            let viewModel = AnalysisFlowViewModel(
                draft: draft,
                repository: environment.analyses,
                uploader: uploader,
                userId: userId
            )
            model = viewModel
            viewModel.start()
        }
        .onChange(of: isFinished) { _, finished in
            guard finished, case .finished(let analysis) = model?.phase else { return }
            cache(analysis)
            Task { await environment.refreshUsage() }
        }
    }

    private var isFinished: Bool {
        if case .finished = model?.phase { return true }
        return false
    }

    private var uploader: ImageUploading {
        if AppConfig.useMockData || AppConfig.isUITesting { return MockImageUploader() }
        return StorageService(
            tokenProvider: KeychainTokenProvider(keychain: environment.keychain) {
                await environment.auth.restore()
            }
        )
    }

    private func cache(_ analysis: Analysis) {
        modelContext.insert(CachedAnalysis.from(analysis))
        try? modelContext.save()
    }

    /// Spec §48: never silently discard a pending upload. If the user backs out
    /// of a failure with an image still in hand, it is kept so the app can
    /// offer to try again later.
    private func persistPendingUpload() {
        guard case .failed = model?.phase, let imageData = draft.imageData else { return }
        modelContext.insert(
            PendingUpload(
                idempotencyKey: draft.idempotencyKey,
                imageData: imageData,
                productUrlString: draft.productUrl,
                userNote: draft.userNote,
                inputTypeRaw: draft.inputType.rawValue,
                lastErrorMessage: {
                    if case .failed(let error) = model?.phase { return error.userMessage }
                    return nil
                }()
            )
        )
        try? modelContext.save()
    }
}

#Preview("Analysis flow") {
    AnalysisFlowView(draft: AnalysisRequestDraft(inputType: .photo))
        .environment(AppEnvironment.preview)
        .modelContainer(LocalStore.makeContainer(inMemory: true))
}
