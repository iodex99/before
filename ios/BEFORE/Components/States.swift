import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — loading, empty, and error states.
//
// Spec §84: every major screen defines all four of loading / empty / success /
// failure. No blank white screens. These are the three that are easy to forget.
// =============================================================================

public struct EmptyState: View {
    private let title: String
    private let message: String
    private let systemImage: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        title: String,
        message: String,
        systemImage: String = "sparkles",
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: BeforeTheme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(BeforeTheme.tertiaryText)

            Text(title)
                .font(BeforeTheme.Typeface.title)
                .foregroundStyle(BeforeTheme.primaryText)
                .multilineTextAlignment(.center)

            Text(message)
                .font(BeforeTheme.Typeface.callout)
                .foregroundStyle(BeforeTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                BeforeSecondaryButton(actionTitle, action: action)
                    .padding(.top, BeforeTheme.Spacing.s)
                    .frame(maxWidth: 260)
            }
        }
        .padding(BeforeTheme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}

public struct ErrorState: View {
    private let title: String
    private let message: String
    private let retry: (() -> Void)?
    private let cancel: (() -> Void)?

    public init(
        title: String = "Something went wrong.",
        message: String,
        retry: (() -> Void)? = nil,
        cancel: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.retry = retry
        self.cancel = cancel
    }

    public var body: some View {
        VStack(spacing: BeforeTheme.Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(BeforeTheme.warning)

            Text(title)
                .font(BeforeTheme.Typeface.title)
                .foregroundStyle(BeforeTheme.primaryText)
                .multilineTextAlignment(.center)

            Text(message)
                .font(BeforeTheme.Typeface.callout)
                .foregroundStyle(BeforeTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: BeforeTheme.Spacing.s) {
                if let retry { BeforeButton("Try again", action: retry) }
                if let cancel { BeforeTextButton("Cancel", action: cancel) }
            }
            .padding(.top, BeforeTheme.Spacing.s)
            .frame(maxWidth: 320)
        }
        .padding(BeforeTheme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// =============================================================================
// Analysis loading
//
// Spec §15: stages, not a fifteen-second spinner. The copy describes what the
// pipeline is actually doing and never implies a human is looking at it.
// =============================================================================

public struct AnalysisStage: Equatable, Sendable {
    public let title: String
    public init(_ title: String) { self.title = title }

    public static let all: [AnalysisStage] = [
        AnalysisStage("Looking at the product"),
        AnalysisStage("Checking your closet"),
        AnalysisStage("Thinking about value"),
        AnalysisStage("Building your verdict"),
    ]
}

public struct LoadingAnalysisView: View {
    private let stages: [AnalysisStage]
    private let onCancel: (() -> Void)?

    @State private var currentIndex = 0
    @State private var timer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(stages: [AnalysisStage] = AnalysisStage.all, onCancel: (() -> Void)? = nil) {
        self.stages = stages
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: BeforeTheme.Spacing.xxl) {
            Spacer()

            VStack(alignment: .leading, spacing: BeforeTheme.Spacing.l) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    HStack(spacing: BeforeTheme.Spacing.m) {
                        stageIcon(for: index)
                            .frame(width: 20)
                        Text(stage.title)
                            .font(BeforeTheme.Typeface.body)
                            .foregroundStyle(
                                index <= currentIndex
                                    ? BeforeTheme.primaryText
                                    : BeforeTheme.tertiaryText
                            )
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: 300)

            Spacer()

            if let onCancel {
                BeforeTextButton("Cancel", action: onCancel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BeforeTheme.background.ignoresSafeArea())
        .onAppear(perform: startAdvancing)
        .onDisappear { timer?.invalidate(); timer = nil }
        .accessibilityElement(children: .ignore)
        // One announcement rather than four competing ones.
        .accessibilityLabel("Analysing. \(stages[min(currentIndex, stages.count - 1)].title).")
    }

    @ViewBuilder
    private func stageIcon(for index: Int) -> some View {
        if index < currentIndex {
            Image(systemName: "checkmark").foregroundStyle(BeforeTheme.success)
        } else if index == currentIndex {
            ProgressView().controlSize(.small).tint(BeforeTheme.accent)
        } else {
            Circle().fill(BeforeTheme.divider).frame(width: 6, height: 6)
        }
    }

    /// The stages are indicative pacing, not real progress reporting — the
    /// backend does not stream stage updates. They stop at the last stage
    /// rather than looping, so nothing claims to have finished before it has.
    private func startAdvancing() {
        guard !reduceMotion else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { timer in
            Task { @MainActor in
                if currentIndex < stages.count - 1 {
                    withAnimation(BeforeTheme.Motion.standard) { currentIndex += 1 }
                } else {
                    timer.invalidate()
                }
            }
        }
    }
}
