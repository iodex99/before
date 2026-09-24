import SwiftData
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — app entry point.
//
// Spec §83: the UI is on screen before anything talks to the network. Launch
// does no blocking work — bootstrap() runs in a task after the first frame.
// =============================================================================

@main
struct BEFOREApp: App {
    @State private var environment: AppEnvironment
    private let modelContainer: ModelContainer

    init() {
        let appEnvironment: AppEnvironment
        if AppConfig.useMockData || AppConfig.isUITesting {
            appEnvironment = .preview
        } else {
            appEnvironment = .live()
        }
        _environment = State(initialValue: appEnvironment)
        modelContainer = LocalStore.makeContainer()

        if AppConfig.isUITesting {
            // No telemetry from an automated run.
            Analytics.configure(sink: NoOpAnalyticsSink())
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .modelContainer(modelContainer)
                .tint(BeforeTheme.accent)
                .task { await environment.bootstrap() }
        }
    }
}

// =============================================================================
// Root
// =============================================================================

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch environment.auth.state {
            case .unknown:
                // Not a spinner screen: the brand mark, briefly, while the
                // session is restored. Usually a single frame.
                LaunchView()

            case .signedOut:
                OnboardingView()

            case .signedIn:
                if environment.hasCompletedOnboarding {
                    MainTabView()
                } else {
                    // Signed in but never answered the two preference
                    // questions — finish those before the app proper.
                    OnboardingView(startAtPreferences: true)
                }
            }
        }
        .animation(BeforeTheme.Motion.standard, value: environment.auth.state)
        .onChange(of: scenePhase) { _, phase in
            // A share can arrive while the app is backgrounded; pick it up on
            // the way back in.
            if phase == .active { environment.drainSharedInbox() }
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            BeforeTheme.background.ignoresSafeArea()
            Text("BEFORE")
                .font(BeforeTheme.Typeface.hero)
                .tracking(4)
                .foregroundStyle(BeforeTheme.primaryText)
        }
        .accessibilityLabel("BEFORE, loading")
    }
}

// =============================================================================
// Tabs — Home, Saved, History, Profile (spec §8). No "AI chat" tab.
// =============================================================================

struct MainTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection: Tab = .home

    enum Tab: Hashable { case home, saved, history, profile }

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)

            SavedView()
                .tabItem { Label("Saved", systemImage: "bookmark") }
                .tag(Tab.saved)

            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
                .tag(Tab.history)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person") }
                .tag(Tab.profile)
        }
        .tint(BeforeTheme.accent)
        // A shared item always lands on Home, where the check flow lives.
        .onChange(of: environment.pendingSharedPayload?.id) { _, newValue in
            if newValue != nil { selection = .home }
        }
    }
}

#Preview("Root") {
    RootView().environment(AppEnvironment.preview)
}
