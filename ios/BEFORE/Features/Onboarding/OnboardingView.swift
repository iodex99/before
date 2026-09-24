import AuthenticationServices
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — onboarding.
//
// Four screens, all skippable past the sign-in (spec §7). Optimised for one
// thing: getting to a first analysis. There is no tutorial, no permission
// prompt, and no notification request here (spec §64).
// =============================================================================

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var step: Step
    @State private var focus: ShoppingFocus?
    @State private var priorities: Set<ShoppingPriority> = []
    @State private var showingHowItWorks = false
    @State private var isSaving = false

    enum Step: Int, CaseIterable { case welcome, focus, priorities, ready }

    init(startAtPreferences: Bool = false) {
        _step = State(initialValue: startAtPreferences ? .focus : .welcome)
    }

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome { progressBar }

            Group {
                switch step {
                case .welcome: welcome
                case .focus: focusStep
                case .priorities: prioritiesStep
                case .ready: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .beforeScreen()
        .animation(BeforeTheme.Motion.standard, value: step)
        .sheet(isPresented: $showingHowItWorks) { HowItWorksSheet() }
        .onAppear { Analytics.track(.onboardingStarted) }
    }

    // MARK: Progress

    private var progressBar: some View {
        HStack(spacing: BeforeTheme.Spacing.xs) {
            ForEach(Step.allCases.dropFirst(), id: \.rawValue) { candidate in
                Capsule()
                    .fill(candidate.rawValue <= step.rawValue
                          ? BeforeTheme.primaryText
                          : BeforeTheme.divider)
                    .frame(height: 3)
            }
        }
        .padding(.top, BeforeTheme.Spacing.l)
        .accessibilityHidden(true)
    }

    // MARK: 1 — Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.l) {
            Spacer()

            Text("BEFORE")
                .font(BeforeTheme.Typeface.caption.weight(.semibold))
                .tracking(4)
                .foregroundStyle(BeforeTheme.secondaryText)

            Text("Before you buy it,\nask BEFORE.")
                .font(BeforeTheme.Typeface.hero)
                .tracking(BeforeTheme.displayTracking)
                .foregroundStyle(BeforeTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your second opinion for the things you're thinking about.")
                .font(BeforeTheme.Typeface.body)
                .foregroundStyle(BeforeTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            VStack(spacing: BeforeTheme.Spacing.m) {
                SignInWithAppleButton(.continue) { request in
                    environment.auth.prepare(request: request)
                } onCompletion: { result in
                    Task {
                        await environment.auth.handle(result)
                        if environment.auth.state.isSignedIn {
                            await environment.syncDeviceSettings()
                            step = .focus
                        }
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: BeforeTheme.Sizing.buttonHeight)
                .clipShape(RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous))

                BeforeTextButton("See how it works") { showingHowItWorks = true }

                if let error = environment.auth.lastError {
                    Text(error)
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.destructive)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.bottom, BeforeTheme.Spacing.xl)
        }
    }

    // MARK: 2 — What do you shop for

    private var focusStep: some View {
        stepLayout(
            title: "What do you shop for most?",
            subtitle: nil,
            canContinue: focus != nil,
            onContinue: { step = .priorities }
        ) {
            VStack(spacing: BeforeTheme.Spacing.m) {
                ForEach(ShoppingFocus.allCases) { option in
                    SelectableRow(
                        title: option.title,
                        isSelected: focus == option
                    ) {
                        focus = option
                    }
                }
            }
        }
    }

    // MARK: 3 — What matters most

    private var prioritiesStep: some View {
        stepLayout(
            title: "What matters most when you buy?",
            subtitle: "Choose up to three.",
            canContinue: !priorities.isEmpty,
            onContinue: { step = .ready }
        ) {
            // A flow layout would reflow at accessibility sizes; a simple
            // wrapping grid keeps the tap targets honest.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: BeforeTheme.Spacing.s)],
                spacing: BeforeTheme.Spacing.s
            ) {
                ForEach(ShoppingPriority.allCases) { priority in
                    SelectableChip(
                        title: priority.title,
                        isSelected: priorities.contains(priority),
                        isDisabled: priorities.count >= 3 && !priorities.contains(priority)
                    ) {
                        if priorities.contains(priority) {
                            priorities.remove(priority)
                        } else if priorities.count < 3 {
                            priorities.insert(priority)
                        }
                    }
                }
            }
        }
    }

    // MARK: 4 — Ready

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.l) {
            Spacer()

            Text("BEFORE learns from your decisions so the advice gets better over time.")
                .font(BeforeTheme.Typeface.hero)
                .tracking(BeforeTheme.displayTracking)
                .foregroundStyle(BeforeTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text("You don't need to add your whole closet. It picks things up as you shop.")
                .font(BeforeTheme.Typeface.body)
                .foregroundStyle(BeforeTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            BeforeButton("Start checking", isLoading: isSaving) {
                Task { await finish() }
            }
            .padding(.bottom, BeforeTheme.Spacing.xl)
        }
    }

    // MARK: Shared layout

    @ViewBuilder
    private func stepLayout<Content: View>(
        title: String,
        subtitle: String?,
        canContinue: Bool,
        onContinue: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: BeforeTheme.Spacing.s) {
                Text(title)
                    .font(BeforeTheme.Typeface.hero)
                    .tracking(BeforeTheme.displayTracking)
                    .foregroundStyle(BeforeTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(BeforeTheme.Typeface.callout)
                        .foregroundStyle(BeforeTheme.secondaryText)
                }
            }
            .padding(.top, BeforeTheme.Spacing.xxl)

            ScrollView { content() }

            Spacer(minLength: 0)

            VStack(spacing: BeforeTheme.Spacing.s) {
                BeforeButton("Continue", action: onContinue)
                    .disabled(!canContinue)
                // Every preference step is skippable: activation beats a
                // complete profile (spec §7).
                BeforeTextButton("Skip for now") { step = .ready }
            }
            .padding(.bottom, BeforeTheme.Spacing.xl)
        }
    }

    // MARK: Completion

    private func finish() async {
        isSaving = true
        defer { isSaving = false }

        var update = ProfileUpdate.fromDeviceSettings()
        update.shoppingFocus = focus?.rawValue
        if !priorities.isEmpty {
            update.shoppingPriorities = priorities.map(\.rawValue)
        }
        update.onboardingCompleted = true

        // A failed preference save must not trap someone in onboarding. The
        // answers are re-askable in Profile, the app is not.
        _ = try? await environment.profiles.updatePreferences(update)
        await environment.refreshProfile()

        environment.hasCompletedOnboarding = true
        Analytics.track(.onboardingCompleted)
    }
}

// MARK: - Pieces

struct SelectableRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(BeforeTheme.Typeface.body)
                    .foregroundStyle(BeforeTheme.primaryText)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(BeforeTheme.accent)
                }
            }
            .padding(BeforeTheme.Spacing.l)
            .frame(minHeight: BeforeTheme.Sizing.minimumTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                    .fill(isSelected ? BeforeTheme.accentSubtle : BeforeTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                    .stroke(isSelected ? BeforeTheme.accent : BeforeTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct SelectableChip: View {
    let title: String
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BeforeTheme.Typeface.callout)
                .foregroundStyle(
                    isDisabled ? BeforeTheme.tertiaryText
                        : isSelected ? BeforeTheme.accent : BeforeTheme.primaryText
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: BeforeTheme.Sizing.minimumTouchTarget)
                .background(
                    Capsule().fill(isSelected ? BeforeTheme.accentSubtle : BeforeTheme.surface)
                )
                .overlay(
                    Capsule().stroke(isSelected ? BeforeTheme.accent : BeforeTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct HowItWorksSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let steps = [
        ("camera.viewfinder", "See something", "A photo, a screenshot, or a link from any shop."),
        ("square.and.arrow.up", "Send it to BEFORE", "From the app, or straight from the share sheet."),
        ("checkmark.seal", "Get a straight answer", "BUY, WAIT, or BYE — and the reasoning behind it."),
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xl) {
                ForEach(steps, id: \.0) { icon, title, detail in
                    HStack(alignment: .top, spacing: BeforeTheme.Spacing.l) {
                        Image(systemName: icon)
                            .font(.title3)
                            .foregroundStyle(BeforeTheme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xs) {
                            Text(title)
                                .font(BeforeTheme.Typeface.headline)
                                .foregroundStyle(BeforeTheme.primaryText)
                            Text(detail)
                                .font(BeforeTheme.Typeface.callout)
                                .foregroundStyle(BeforeTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer()

                Text("BEFORE gives AI-generated advice based on what you tell it. It won't always be right, and it will sometimes tell you not to buy.")
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, BeforeTheme.Spacing.xl)
            .beforeScreen()
            .navigationTitle("How it works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview("Onboarding") {
    OnboardingView().environment(AppEnvironment.preview)
}
